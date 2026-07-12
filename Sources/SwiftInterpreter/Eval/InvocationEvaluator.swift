import Foundation
import SwiftSyntax

extension Interpreter {
    func collectArguments(of call: FunctionCallExprSyntax, in env: Environment) throws -> CallArguments {
        var arguments: [CallArguments.Argument] = []
        for labeled in call.arguments {
            arguments.append(.init(label: labeled.label?.text, value: try evaluate(labeled.expression, in: env)))
        }
        if let trailing = call.trailingClosure {
            arguments.append(.init(
                label: nil, value: .closure(try makeClosure(trailing, in: env)),
                isTrailing: true))
        }
        for extra in call.additionalTrailingClosures {
            arguments.append(.init(
                label: extra.label.text,
                value: .closure(try makeClosure(extra.closure, in: env)),
                isTrailing: true))
        }
        return CallArguments(arguments: arguments)
    }

    /// A host-extension init fits only when labels align AND every
    /// argument's RUNTIME type satisfies the parameter annotation.
    func extensionInitFits(_ decl: InitializerDeclSyntax, args: CallArguments) -> Bool {
        let parameters = initializerMetadata(for: decl).parameters
        var remaining = args.arguments
        for parameter in parameters {
            if let index = remaining.firstIndex(where: { $0.label == parameter.label }) {
                let argument = remaining.remove(at: index)
                guard let annotation = parameter.typeAnnotation?.trimmedDescription,
                      valueIsType(argument.value, annotation) else { return false }
            } else if parameter.defaultValue == nil {
                return false
            }
        }
        return remaining.isEmpty
    }

    func invoke(_ callee: RuntimeValue, with args: CallArguments, node: some SyntaxProtocol) throws -> RuntimeValue {
        var args = args
        switch callee {
        case .closure, .type:
            break // user code: `inout` slots flow through to bindParameters
        default:
            args = args.unwrappingInoutSlots()
        }
        switch callee {
        case .nilValue:
            return .none() // optional chaining through an untyped nil method
        case .optional(let optional):
            let explicitlyChained = Syntax(node).as(FunctionCallExprSyntax.self)?
                .calledExpression.is(OptionalChainingExprSyntax.self) == true
            guard let wrapped = optional.wrapped else {
                if optional.isImplicitlyUnwrapped && !explicitlyChained {
                    throw error(node, "unexpectedly found nil while implicitly unwrapping")
                }
                return callee
            }
            let result = try invoke(wrapped, with: args, node: node)
            return optional.isImplicitlyUnwrapped && !explicitlyChained
                ? result : result.liftedToOptional()
        case .instance(let instance) where instance.symbol.conformsToLayout:
            // Parenthesized custom layouts use the value-call spelling:
            // `(FlowLayout(spacing: 8)) { children }`. SwiftUI supplies
            // Layout.callAsFunction; that method is not present in project
            // source, so retain the built children on the layout instance
            // and let the host registry render its documented flow fallback.
            guard let content = args.firstUnlabeledClosure else {
                if args.isEmpty { return callee }
                throw error(node, "a Layout value needs a content closure")
            }
            let children = try callBuilderClosure(content, arguments: [])
            instance.properties[StructSymbol.layoutChildrenKey] = Box(
                RuntimeValue.native(children).copiedForValueSemantics())
            guard let registry else {
                return try groupViews(children)
            }
            return registry.makeRenderable(instance: instance, interpreter: self)
        case .instance(let instance) where instance.symbol.methods["callAsFunction"] != nil:
            // SwiftUI action values (`openWindow(id:)`, OpenCocoaWindowAction)
            // — instances invoke through callAsFunction.
            if let overloads = instance.symbol.methods["callAsFunction"],
               let method = chooseFunction(from: overloads, for: args) ?? overloads.first,
               let body = method.body {
                let closure = makeFunctionClosure(
                    method, body: body, captured: instanceMethodEnvironment(instance))
                return try callWithArguments(closure, args: args, node: Syntax(node))
            }
            return .void
        case .type(let symbol):
            // `SomeLayout { views }` — Layout.callAsFunction sugar. The
            // children stash on the instance; the registry wraps it in a
            // REAL Layout whose sizeThatFits/placeSubviews run interpreted
            // (headless registries keep the flow fallback).
            if symbol.conformances.contains("Layout"),
               args.firstUnlabeledClosure != nil {
                let instance = try instantiate(symbol, with: args, node: Syntax(node))
                guard case .instance(let layoutInstance) = instance, let registry else {
                    return instance
                }
                return registry.makeRenderable(instance: layoutInstance, interpreter: self)
            }
            do {
                return try instantiate(symbol, with: args, node: Syntax(node))
            } catch let bindingError as RuntimeError
                where !bindingError.fatal
                    && (bindingError.message.contains("missing argument")
                        || bindingError.message.contains("doesn't match a stored property")
                        || bindingError.message.contains("trailing closure doesn't match")) {
                // A vendored type sharing a host type's name (Lottie's
                // `struct Color` vs SwiftUI.Color): binding fails before any
                // init body runs, so retrying the registry constructor is
                // safe — real Swift overload-resolves across modules.
                guard let ctor = registry?.constructor(named: symbol.name) else {
                    throw bindingError
                }
                do {
                    return try ctor.invoke(args, self)
                } catch {
                    if symbol.name == "Section" {
                        FileHandle.standardError.write(Data("SECTION RETRY FAILED: \(error)\n".utf8))
                    }
                    throw bindingError
                }
            }
        case .closure(let closure):
            return try callWithArguments(closure, args: args, node: Syntax(node))
        case .hostFunction(let function):
            // Host-type EXTENSION inits are real overloads of the registry
            // constructor: a STRICTLY-fitting one wins (apple-browsers'
            // `extension Text { init(_ item: InlineTextItem) }` beats
            // stringification). The RUNNING init is excluded, so its inner
            // `Text(value)` reaches the registry instead of recursing; the
            // body runs with a writable `self` like enum inits.
            if let extensionSymbol = hostExtensionSymbols[function.name] {
                let available = extensionSymbol.initializers.filter {
                    !activeInitializers.contains($0.id) && !Interpreter.isCodableInit($0)
                }
                // POSITIVE type match required: every argument's runtime
                // type must satisfy the parameter annotation (`is`
                // semantics). Merely label-shaped fits chain-walked the
                // merge's MANY one-arg Text inits 152 deep in
                // apple-browsers before reaching the registry.
                if let chosen = available.first(where: { extensionInitFits($0, args: args) }),
                   let body = chosen.body {
                    let inserted = activeInitializers.insert(chosen.id).inserted
                    defer { if inserted { activeInitializers.remove(chosen.id) } }
                    let env = Environment(parent: globals)
                    env.define("self", .void)
                    let parameters = initializerMetadata(for: chosen).parameters
                    let closure = ClosureValue(
                        parameters: parameters, body: body.statements, captured: env)
                    closure.debugName = "extInit:\(function.name)"
                    _ = try callWithArguments(closure, args: args, node: Syntax(node))
                    let assigned = env.lookup("self") ?? .void
                    if case .void = assigned {
                        // `self` never assigned — fall through to the ctor.
                    } else {
                        return assigned
                    }
                }
            }
            do {
                return try function.invoke(args, self)
            } catch let e as RuntimeError where e.line == 0 {
                // Gateways throw unlocated errors; pin them to the call site.
                throw error(node, e.message)
            }
        case .enumType(let symbol):
            // `Icon(rawValue: 3)` — the raw-value initializer.
            if args.arguments.count == 1, let raw = args.labeled("rawValue") {
                let matched = symbol.cases
                    .first { (try? Builtins.areEqual($0.rawValue, raw)) == true }
                    .map { RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name)) }
                return .optional(matched, wrappedTypeName: symbol.name)
            }
            // Custom enum inits run with a WRITABLE `self` (`self = .primary`);
            // the final self resolves against the enum's own type context.
            // Codable inits (init(from: Decoder)) are decoder-only — a
            // positional value tries RAW-VALUE matching instead.
            let constructible = symbol.initializers.filter {
                !Interpreter.isCodableInit($0) && !activeInitializers.contains($0.id)
            }
            if constructible.isEmpty, args.arguments.count == 1,
               let raw = args.positional(0) {
                if let matched = symbol.cases
                    .first(where: { (try? Builtins.areEqual($0.rawValue, raw)) == true }) {
                    return .enumCase(EnumCaseValue(symbol: symbol, name: matched.name))
                }
            }
            // Generated NAMESPACE enums claim ubiquitous names (SwiftGen's
            // Loc.Text registering bare `Text`): unless an init POSITIVELY
            // fits the arguments' runtime types, and a host constructor
            // shares the name, real overload resolution crosses the module
            // boundary — Text(verbatim:) is SwiftUI's. A label-shaped loose
            // fit chain-walked apple-browsers' Text extension inits 152
            // deep (`Text(value)` inside `init(_ textItem:)` re-entered —
            // the exclusion above plus this positive gate end the cycle).
            if constructible.first(where: { extensionInitFits($0, args: args) }) == nil,
               !args.arguments.isEmpty,
               let ctor = registry?.constructor(named: symbol.name) {
                return try ctor.invoke(args, self)
            }
            if !constructible.isEmpty {
                let chosen = chooseInitializer(from: constructible, for: args)
                guard let body = chosen.body else {
                    throw error(node, "init of '\(symbol.name)' has no body")
                }
                let bracketed = activeInitializers.insert(chosen.id).inserted
                defer { if bracketed { activeInitializers.remove(chosen.id) } }
                let env = Environment(parent: globals)
                env.define("self", .void)
                let parameters = initializerMetadata(for: chosen).parameters
                let closure = ClosureValue(parameters: parameters, body: body.statements, captured: env)
                closure.debugName = "enumInit:\(symbol.name)"
                _ = try callWithArguments(closure, args: args, node: Syntax(node))
                let assigned = env.lookup("self") ?? .void
                let initialized = try resolveAnnotated(assigned, typeName: symbol.name)
                return chosen.optionalMark != nil
                    ? initialized.liftedToOptional(wrappedTypeName: symbol.name)
                    : initialized
            }
            // Shadowed host-type names (Aidoku's nested `enum State` vs
            // SwiftUI State(initialValue:)): fall through to the registry
            // constructor, the iteration-103 rule for enums.
            if let ctor = registry?.constructor(named: symbol.name) {
                return try ctor.invoke(args, self)
            }
            throw error(node, "'\(symbol.name)' has no matching initializer")
        case .implicitMember(let name):
            return .native(ImplicitMemberCall(name: name, arguments: args))
        case .host(let any) where any is ImplicitMemberCall
            && (any as! ImplicitMemberCall).arguments.arguments.isEmpty:
            // A TYPED marker called (`AnyTransition.asymmetric(…)` where the
            // program extends AnyTransition): the call re-mints with its
            // arguments, exactly like a bare implicit member. Markers that
            // ALREADY carry arguments keep the not-callable throw — callers'
            // fallbacks (gateway retries) depend on it.
            let call = any as! ImplicitMemberCall
            return .native(ImplicitMemberCall(
                name: call.name, arguments: args, typeHint: call.typeHint))
        case .host(let any) where any is ChainedImplicitCall:
            let chained = any as! ChainedImplicitCall
            return .native(ChainedImplicitCall(base: chained.base, member: chained.member, arguments: args))
        case .host(let any) where any is HostTypeMarker:
            let marker = any as! HostTypeMarker
            if assumesCompiledImports, marker.name.contains("."),
               let ctor = registry?.constructor(named: marker.name) {
                // Macro-generated NESTED types called as constructors
                // (TicTacToe.State() from @Reducer): absorbing bags. Plain
                // markers keep the fast throw — launch-hook tolerance
                // depends on it.
                return try ctor.invoke(args, self)
            }
            throw error(node, "'\(marker.name)' has no interpreter constructor — only its static members (like \(marker.name).something) are supported")
        case .host(let any) where any is KeyPathStub:
            // SE-0249 keypath-as-function: `(\.feature1)(subject)` reads the
            // property off the argument (TCA's case-keypath action mapping).
            if let subject = args.positional(0) {
                return try applyKeyPath(any as! KeyPathStub, to: subject)
            }
            return callee
        case .host(let any) where any is InertCallable:
            return callee // inert-chainable host stub call
        default:
            if args.arguments.isEmpty {
                // `childCore()` on an @autoclosure parameter bound to a
                // plain value: calling the deferred expression yields the
                // value (compiled sources only call callables, so a
                // zero-arg call on data is always this shape).
                return callee
            }
            throw error(node, "\(callee.stringified) is not callable")
        }
    }

    /// Names whose values must be available after this closure escapes. The
    /// parser already guarantees valid lexical Swift; this lightweight free-
    /// variable pass keeps locally declared names out while retaining outer
    /// variables referenced by nested closure construction as native Swift
    /// must. Capture-list initializers are handled separately at creation.
    private func outerReferences(
        in closure: ClosureExprSyntax,
        parameters: [ClosureValue.Parameter]
    ) -> Set<String> {
        var references: Set<String> = []

        func patternNames(_ pattern: PatternSyntax) -> Set<String> {
            var names: Set<String> = []
            func collect(_ node: Syntax) {
                if let identifier = node.as(IdentifierPatternSyntax.self) {
                    names.insert(identifier.identifier.text)
                    return
                }
                for child in node.children(viewMode: .sourceAccurate) {
                    collect(child)
                }
            }
            collect(Syntax(pattern))
            return names
        }

        func closureParameters(_ nested: ClosureExprSyntax) -> Set<String> {
            guard let input = nested.signature?.parameterClause else { return [] }
            switch input {
            case .simpleInput(let shorthand):
                return Set(shorthand.map { $0.name.text })
            case .parameterClause(let clause):
                return Set(clause.parameters.map {
                    ($0.secondName ?? $0.firstName).text
                })
            }
        }

        func note(_ name: String, bound: Set<String>) {
            if !bound.contains(name) { references.insert(name) }
        }

        func collectPatternReferences(_ pattern: PatternSyntax, bound: Set<String>) {
            func collect(_ node: Syntax) {
                if node.is(IdentifierPatternSyntax.self) { return }
                if let expression = node.as(ExpressionPatternSyntax.self) {
                    collectReferences(Syntax(expression.expression), bound: bound)
                    return
                }
                for child in node.children(viewMode: .sourceAccurate) {
                    collect(child)
                }
            }
            collect(Syntax(pattern))
        }

        func collectConditions(
            _ conditions: ConditionElementListSyntax, bound initial: Set<String>
        ) -> Set<String> {
            var bound = initial
            for element in conditions {
                switch element.condition {
                case .expression(let expression):
                    collectReferences(Syntax(expression), bound: bound)
                case .optionalBinding(let binding):
                    if let initializer = binding.initializer?.value {
                        collectReferences(Syntax(initializer), bound: bound)
                    } else if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                        note(identifier.identifier.text, bound: bound)
                    }
                    bound.formUnion(patternNames(binding.pattern))
                case .matchingPattern(let matching):
                    collectReferences(Syntax(matching.initializer.value), bound: bound)
                    collectPatternReferences(matching.pattern, bound: bound)
                    bound.formUnion(patternNames(matching.pattern))
                case .availability:
                    break
                }
            }
            return bound
        }

        func collectItems(
            _ items: CodeBlockItemListSyntax, bound initial: Set<String>
        ) {
            var bound = initial

            // Local functions and types are visible throughout their lexical
            // block. Variables are introduced in source order below.
            for item in items {
                guard case .decl(let declaration) = item.item else { continue }
                if let function = declaration.as(FunctionDeclSyntax.self) {
                    bound.insert(function.name.text)
                } else if let type = declaration.as(StructDeclSyntax.self) {
                    bound.insert(type.name.text)
                } else if let type = declaration.as(ClassDeclSyntax.self) {
                    bound.insert(type.name.text)
                } else if let type = declaration.as(EnumDeclSyntax.self) {
                    bound.insert(type.name.text)
                } else if let type = declaration.as(ActorDeclSyntax.self) {
                    bound.insert(type.name.text)
                } else if let alias = declaration.as(TypeAliasDeclSyntax.self) {
                    bound.insert(alias.name.text)
                }
            }

            for item in items {
                if case .decl(let declaration) = item.item,
                   let variable = declaration.as(VariableDeclSyntax.self) {
                    for binding in variable.bindings {
                        if let initializer = binding.initializer?.value {
                            collectReferences(Syntax(initializer), bound: bound)
                        }
                        let names = patternNames(binding.pattern)
                        if let accessor = binding.accessorBlock {
                            collectReferences(
                                Syntax(accessor), bound: bound.union(names))
                        }
                        bound.formUnion(names)
                    }
                    continue
                }
                if case .stmt(let statement) = item.item,
                   let guardStatement = statement.as(GuardStmtSyntax.self) {
                    let succeeding = collectConditions(
                        guardStatement.conditions, bound: bound)
                    collectItems(guardStatement.body.statements, bound: bound)
                    bound = succeeding
                    continue
                }
                collectReferences(Syntax(item), bound: bound)
            }
        }

        func collectReferences(_ node: Syntax, bound: Set<String>) {
            if let nested = node.as(ClosureExprSyntax.self) {
                // Capture-list expressions execute in the enclosing scope.
                // The captured names and closure parameters then shadow that
                // scope in the nested body.
                var nestedBound = bound.union(closureParameters(nested))
                if let captures = nested.signature?.capture?.items {
                    for capture in captures {
                        if let initializer = capture.initializer?.value {
                            collectReferences(Syntax(initializer), bound: bound)
                        } else {
                            note(capture.name.text, bound: bound)
                        }
                        nestedBound.insert(capture.name.text)
                    }
                }
                collectItems(nested.statements, bound: nestedBound)
                return
            }
            if let block = node.as(CodeBlockSyntax.self) {
                collectItems(block.statements, bound: bound)
                return
            }
            if let function = node.as(FunctionDeclSyntax.self) {
                guard let body = function.body else { return }
                var functionBound = bound
                functionBound.insert(function.name.text)
                for parameter in function.signature.parameterClause.parameters {
                    functionBound.insert((parameter.secondName ?? parameter.firstName).text)
                }
                collectItems(body.statements, bound: functionBound)
                return
            }
            if node.is(StructDeclSyntax.self) || node.is(ClassDeclSyntax.self)
                || node.is(EnumDeclSyntax.self) || node.is(ActorDeclSyntax.self)
                || node.is(ProtocolDeclSyntax.self) {
                // Local nominal types cannot close over function locals.
                return
            }
            if let forStatement = node.as(ForStmtSyntax.self) {
                collectReferences(Syntax(forStatement.sequence), bound: bound)
                let bodyBound = bound.union(patternNames(forStatement.pattern))
                collectPatternReferences(forStatement.pattern, bound: bound)
                if let whereClause = forStatement.whereClause {
                    collectReferences(Syntax(whereClause.condition), bound: bodyBound)
                }
                collectItems(forStatement.body.statements, bound: bodyBound)
                return
            }
            if let ifExpression = node.as(IfExprSyntax.self) {
                let bodyBound = collectConditions(ifExpression.conditions, bound: bound)
                collectItems(ifExpression.body.statements, bound: bodyBound)
                switch ifExpression.elseBody {
                case .none:
                    break
                case .codeBlock(let block):
                    collectItems(block.statements, bound: bound)
                case .ifExpr(let nested):
                    collectReferences(Syntax(nested), bound: bound)
                }
                return
            }
            if let whileStatement = node.as(WhileStmtSyntax.self) {
                let bodyBound = collectConditions(whileStatement.conditions, bound: bound)
                collectItems(whileStatement.body.statements, bound: bodyBound)
                return
            }
            if let switchExpression = node.as(SwitchExprSyntax.self) {
                collectReferences(Syntax(switchExpression.subject), bound: bound)
                for switchCase in flattenedSwitchCases(switchExpression) {
                    switch switchCase.label {
                    case .default:
                        collectItems(switchCase.statements, bound: bound)
                    case .case(let label):
                        for item in label.caseItems {
                            collectPatternReferences(item.pattern, bound: bound)
                            let caseBound = bound.union(patternNames(item.pattern))
                            if let whereClause = item.whereClause {
                                collectReferences(
                                    Syntax(whereClause.condition), bound: caseBound)
                            }
                            collectItems(switchCase.statements, bound: caseBound)
                        }
                    }
                }
                return
            }
            if let member = node.as(MemberAccessExprSyntax.self) {
                // The declaration name after a dot is not a free variable.
                // Walking it as a DeclReference (`owner?.name`) would falsely
                // infer an implicit-self capture whenever `self` also has a
                // property called `name`.
                if let base = member.base {
                    collectReferences(Syntax(base), bound: bound)
                }
                return
            }
            if let reference = node.as(DeclReferenceExprSyntax.self) {
                note(reference.baseName.text, bound: bound)
            } else if node.is(SuperExprSyntax.self) {
                note("self", bound: bound)
            } else if node.is(IdentifierPatternSyntax.self) {
                return
            }
            for child in node.children(viewMode: .sourceAccurate) {
                collectReferences(child, bound: bound)
            }
        }

        var initialBound = Set(parameters.map(\.name))
        if let captures = closure.signature?.capture?.items {
            initialBound.formUnion(captures.map { $0.name.text })
        }
        collectItems(closure.statements, bound: initialBound)
        return references
    }

    private func symbolMayResolveInstanceMember(
        _ rawName: String, on instance: Instance
    ) -> Bool {
        let name = rawName.hasPrefix("$") ? String(rawName.dropFirst()) : rawName
        var symbol: StructSymbol? = instance.symbol
        var seen: Set<ObjectIdentifier> = []
        while let current = symbol, seen.insert(ObjectIdentifier(current)).inserted {
            if current.storedProperty(named: name) != nil
                || current.computedProperties[name] != nil
                || current.methods[name] != nil {
                return true
            }
            symbol = current.superclassName.flatMap {
                guard case .type(let parent)? = globals.lookup($0) else { return nil }
                return parent
            }
        }
        for conformance in transitiveConformances(of: instance.symbol) {
            if let ext = hostExtensionSymbols[conformance],
               ext.computedProperties[name] != nil || ext.methods[name] != nil {
                return true
            }
        }
        return false
    }

    private func captureTypeName(
        for value: RuntimeValue, ownership: ReferenceOwnership
    ) -> String? {
        switch value {
        case .instance(let instance):
            return instance.symbol.name + (ownership == .weak ? "?" : "")
        case .optional(let optional):
            return optional.typeName
        default:
            return nil
        }
    }

    func makeClosure(_ closure: ClosureExprSyntax, in env: Environment) throws -> ClosureValue {
        var parameters: [ClosureValue.Parameter] = []
        if let input = closure.signature?.parameterClause {
            switch input {
            case .simpleInput(let shorthand):
                parameters = shorthand.map { .init(name: $0.name.text) }
            case .parameterClause(let clause):
                // Typed closure parameters (`{ (result: Result<…>) in }`)
                // keep their annotations — generic unification reads them.
                parameters = clause.parameters.map {
                    .init(name: ($0.secondName ?? $0.firstName).text, typeAnnotation: $0.type)
                }
            }
        }
        // A capture environment must not retain the source frame itself: doing
        // so would leave the frame's strong `self` reachable behind a
        // `[weak self]` shadow. Globals are a session root and are consulted
        // through a weak parent to avoid globals -> closure -> globals cycles.
        let captured = Environment(parent: globals, retainingParent: false)
        var explicitNames: Set<String> = []
        if let captureList = closure.signature?.capture?.items, !captureList.isEmpty {
            for capture in captureList {
                let name = capture.name.text
                explicitNames.insert(name)
                let capturedValue: RuntimeValue
                if let initializer = capture.initializer?.value {
                    capturedValue = try evaluate(initializer, in: env)
                } else {
                    capturedValue = try resolveIdentifier(name, in: env, node: capture)
                }
                let ownership = ReferenceOwnership(
                    captureSpecifier: capture.specifier)
                captured.define(
                    name, capturedValue,
                    declaredTypeName: captureTypeName(
                        for: capturedValue, ownership: ownership),
                    referenceOwnership: ownership)
            }
        }

        let references = outerReferences(in: closure, parameters: parameters)
        var needsSelf = false
        for name in references where !explicitNames.contains(name) {
            if name == "self" {
                needsSelf = true
                continue
            }
            if let box = env.box(for: name, before: globals) {
                captured.define(name, sharing: box)
                continue
            }
            if case .instance(let instance)? = env.lookup("self"),
               symbolMayResolveInstanceMember(name, on: instance) {
                needsSelf = true
                continue
            }
            // Macro-generated members, host-extension members (`wrappedValue`
            // on Binding), and bare sibling statics may have no collected
            // declaration to consult. Globals and type-looking host names are
            // never implicit self; an otherwise unresolved value-like name is.
            if globals.box(for: name) == nil,
               !name.dropFirst(name.hasPrefix("$") ? 1 : 0).allSatisfy(\.isNumber),
               name.first?.isUppercase != true,
               env.lookup("self") != nil {
                needsSelf = true
            }
        }
        if needsSelf, !explicitNames.contains("self"),
           let selfValue = env.lookup("self") {
            // Source-struct self is a value capture; source-class self retains
            // identity. Environment.define centralizes that distinction.
            captured.define("self", selfValue)
        }

        let value = ClosureValue(
            parameters: parameters, body: closure.statements,
            captured: captured)
        // A closure carries its declaration's lexical type even when a host
        // bridge invokes it later from a different member context. Capturing
        // only the value environment lets same-named nested types resolve in
        // the eventual caller instead of where the closure was written.
        value.lexicalOwner = lexicalOwnerFrames.last
        return value
    }

    func callWithArguments(_ closure: ClosureValue, args: CallArguments, node: Syntax?) throws -> RuntimeValue {
        callDepth += 1
        defer { callDepth -= 1 }
        var insertedFrame: ExtensionFrame?
        if let frame = closure.extensionFrame, activeExtensionFrames.insert(frame).inserted {
            insertedFrame = frame
        }
        defer { if let insertedFrame { activeExtensionFrames.remove(insertedFrame) } }
        var insertedBody: SyntaxIdentifier?
        if let declID = closure.functionDeclID, activeFunctionBodies.insert(declID).inserted {
            insertedBody = declID
        }
        defer { if let insertedBody { activeFunctionBodies.remove(insertedBody) } }
        var pushedLexicalOwner = false
        if let owner = closure.lexicalOwner {
            lexicalOwnerFrames.append(owner)
            pushedLexicalOwner = true
        }
        defer { if pushedLexicalOwner { lexicalOwnerFrames.removeLast() } }

        guard callDepth < callDepthLimit else {
            if let node {
                let located = error(node, "call depth exceeded (possible infinite recursion)")
                throw RuntimeError(
                    message: located.message, line: located.line, column: located.column, fatal: true)
            }
            throw RuntimeError(message: "call depth exceeded (possible infinite recursion)", fatal: true)
        }
        let env = Environment(parent: closure.captured)
        let writeBacks = try bindParameters(of: closure, to: args, into: env, node: node)
        if !closure.genericParameters.isEmpty {
            bindGenericReturnParameter(closure, into: env)
            bindGenericsFromClosureArguments(closure, args: args, into: env)
        }
        // Copy-out for `inout` parameters whose argument wasn't a plain
        // variable (member/subscript lvalues) — applied on normal exit,
        // mirroring Swift's copy-in/copy-out.
        func applyInoutWriteBacks() throws {
            for entry in writeBacks {
                if let target = entry.slot.target, let box = env.box(for: entry.name) {
                    try target.writeOwned(box.value, self)
                }
            }
        }
        if closure.isBuilder {
            let items = try collectBuilderViews(closure.body, in: env)
            try applyInoutWriteBacks()
            // `[X]`-returning builders (custom @resultBuilders' buildBlock)
            // collect into an ARRAY; view-typed ones group as views.
            if closure.builderReturnsArray {
                return .native(items)
            }
            return try groupViews(items)
        }
        enclosingReturnAnnotations.append(closure.returnTypeName)
        defer { enclosingReturnAnnotations.removeLast() }
        if Interpreter.traceStateCells {
            let label = closure.debugName ?? "closure{" + closure.body.description
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ").prefix(48) + "}"
            callStackNames.append(String(label))
        }
        defer { if Interpreter.traceStateCells, !callStackNames.isEmpty { callStackNames.removeLast() } }
        if let names = Self.tracedCallNames, let name = closure.debugName, names.contains(name) {
            Swift.print("⟶ \(name)")
        }
        // An IMPLICIT single-expression return is return-position too: the
        // lone expression evaluates under the declared return type, exactly
        // like an explicit `return expr` (`func countries() -> [Country] {
        // try await call(endpoint:) }` binds the callee's generic Value).
        let singleExpressionBody: Bool = {
            guard closure.body.count == 1, let item = closure.body.first?.item else { return false }
            if case .expr = item { return true }
            return false
        }()
        // A generic function's OWN `-> Entity` must not mask the caller's
        // concrete hint — the ambient annotation is what binds nested hops
        // (`get<Entity> -> Entity { makeRequest(…) }` threads the typed-let).
        let hintIsOwnGeneric: Bool = {
            guard let hint = closure.returnTypeName else { return true }
            return closure.genericParameters.contains { param in
                hint.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                    .contains(Substring(param))
            }
        }()
        let result: StatementResult
        if singleExpressionBody, !hintIsOwnGeneric, let returnHint = closure.returnTypeName {
            result = try withExpectedAnnotation(returnHint) {
                try executeBlock(closure.body, in: env)
            }
        } else {
            result = try executeBlock(closure.body, in: env)
        }
        try applyInoutWriteBacks()
        switch result {
        case .normal(let value), .returnValue(let value):
            if let returnTypeName = closure.returnTypeName {
                return try resolveAnnotated(value, typeName: returnTypeName)
            }
            return value
        case .breakLoop, .continueLoop:
            throw RuntimeError(message: "break/continue escaped a function body")
        }
    }

    /// Return-position generic binding: `func get<Entity: Decodable>(…) -> Entity`
    /// invoked under `let x: [Status] = …` defines Entity as the annotation's
    /// TYPE VALUE in the callee scope — the IceCubes client genre threads it
    /// (get → makeEntityRequest → `decoder.decode(Entity.self, from:)`).
    /// Nested generic calls rebind from the same ambient hint. No hint, no
    /// binding — the parameter stays unresolved exactly as before.
    /// `GET<T>(…, completionHandler: @escaping (Result<T, APIError>) -> Void)`
    /// called with a literal whose parameter is annotated
    /// `(result: Result<PaginatedResponse<Movie>, APIError>) in` — the
    /// annotation IS the call-site type context: unify the declared
    /// function-type parameter against the argument closure's annotations
    /// (the APIService completion genre).
    func bindGenericsFromClosureArguments(
        _ closure: ClosureValue, args: CallArguments, into env: Environment
    ) {
        let unbound = closure.genericParameters.filter { env.lookup($0) == nil }
        guard !unbound.isEmpty else { return }
        for parameter in closure.parameters {
            guard let declared = parameter.typeAnnotation?.trimmedDescription,
                  declared.contains("->"),
                  unbound.contains(where: { declared.contains($0) }) else { continue }
            let argument = args.labeled(parameter.label ?? parameter.name)
                ?? args.lastUnlabeledClosure.map { RuntimeValue.closure($0) }
            guard case .closure(let argClosure)? = argument else { continue }
            let declaredParams = Self.functionTypeParameterList(declared)
            guard declaredParams.count == argClosure.parameters.count else { continue }
            for (declaredType, argParameter) in zip(declaredParams, argClosure.parameters) {
                guard let actual = argParameter.typeAnnotation?.trimmedDescription else { continue }
                unifyGeneric(declaredType, actual, unbound: unbound, into: env)
            }
        }
    }

    /// "(Result<T, E>) -> Void" → ["Result<T, E>"] (attributes stripped,
    /// top-level comma split).
    static func functionTypeParameterList(_ declared: String) -> [String] {
        var text = declared.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("@") {
            guard let space = text.firstIndex(of: " ") else { return [] }
            text = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        guard text.hasPrefix("("), let arrow = text.range(of: "->") else { return [] }
        var depth = 0
        var end: String.Index?
        for index in text.indices {
            let char = text[index]
            if char == "(" { depth += 1 }
            if char == ")" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        guard let end, end < arrow.lowerBound else { return [] }
        let inner = String(text[text.index(after: text.startIndex)..<end])
        return Self.splitTopLevel(inner)
    }

    public static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for char in text {
            switch char {
            case "<", "(", "[": depth += 1; current.append(char)
            case ">", ")", "]": depth -= 1; current.append(char)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(char)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// Structural unification of a declared type against a concrete one:
    /// where the declared node IS an unbound generic, bind it; generic
    /// heads recurse argument-wise (qualification differences in heads are
    /// tolerated — Result vs Swift.Result).
    private func unifyGeneric(
        _ declared: String, _ actual: String, unbound: [String], into env: Environment
    ) {
        let d = strippedAnnotation(declared)
        let a = strippedAnnotation(actual)
        if unbound.contains(d) {
            if env.lookup(d) == nil, let descriptor = typeDescriptor(named: a) {
                env.define(d, descriptor)
            }
            return
        }
        if d.hasPrefix("["), d.hasSuffix("]"), a.hasPrefix("["), a.hasSuffix("]"),
           !d.contains(":"), !a.contains(":") {
            unifyGeneric(
                String(d.dropFirst().dropLast()), String(a.dropFirst().dropLast()),
                unbound: unbound, into: env)
            return
        }
        guard let dLt = d.firstIndex(of: "<"), d.hasSuffix(">"),
              let aLt = a.firstIndex(of: "<"), a.hasSuffix(">") else { return }
        let dArgs = Self.splitTopLevel(String(d[d.index(after: dLt)..<d.index(before: d.endIndex)]))
        let aArgs = Self.splitTopLevel(String(a[a.index(after: aLt)..<a.index(before: a.endIndex)]))
        guard dArgs.count == aArgs.count else { return }
        for (dChild, aChild) in zip(dArgs, aArgs) {
            unifyGeneric(dChild, aChild, unbound: unbound, into: env)
        }
    }

    func bindGenericReturnParameter(_ closure: ClosureValue, into env: Environment) {
        guard let returnName = closure.returnTypeName,
              let hint = expectedAnnotationStack.last else { return }
        let hintText = strippedAnnotation(hint)
        if closure.genericParameters.contains(returnName) {
            if let descriptor = typeDescriptor(named: hintText) {
                env.define(returnName, descriptor)
            }
            return
        }
        // `-> [Entity]` under a `[Status]` annotation binds the ELEMENT.
        if returnName.hasPrefix("["), returnName.hasSuffix("]"),
           hintText.hasPrefix("["), hintText.hasSuffix("]") {
            let element = strippedAnnotation(String(returnName.dropFirst().dropLast()))
            guard closure.genericParameters.contains(element) else { return }
            let hintElement = String(hintText.dropFirst().dropLast())
            if let descriptor = typeDescriptor(named: hintElement) {
                env.define(element, descriptor)
            }
        }
    }

    /// `[Status]` → the decode bridge's array-literal-of-type shape;
    /// `Status` → the declared `.type`/`.enumType`. Unknown names: nil.
    private func typeDescriptor(named text: String) -> RuntimeValue? {
        let name = strippedAnnotation(text)
        if name.hasPrefix("["), name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast())
            guard !inner.contains(":") else { return nil } // dictionaries later
            return typeDescriptor(named: inner).map { .native([$0]) }
        }
        // A generic APPLICATION (`PaginatedResponse<Movie>`) rides textually
        // when its head is a declared type — decode re-parses it to bind
        // the struct's own generics.
        if let angle = name.firstIndex(of: "<"), name.hasSuffix(">"),
           typeValue(named: String(name[..<angle])) != nil {
            return .native(GenericApplication(text: name))
        }
        return typeValue(named: name)
    }

    private func strippedAnnotation(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name = String(name.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// Label-aware binding: labeled arguments match parameter labels, omitted
    /// defaulted parameters (including in the middle) fall back to their
    /// defaults, positional arguments fill unlabeled parameters in order, and
    /// the unlabeled trailing closure binds to the LAST unbound parameter.
    /// No-parameter closures get `$0`, `$1`, … shorthand bindings.
    /// Returns the copy-out list for `inout` arguments that need a write-back
    /// on return (box-backed ones alias live and need none).
    @discardableResult
    func bindParameters(
        of closure: ClosureValue, to args: CallArguments, into env: Environment, node: Syntax?
    ) throws -> [(name: String, slot: InoutSlot)] {
        if closure.parameters.isEmpty {
            let values = args.arguments.map { $0.value.unwrappingInoutSlot }
            // A single tuple argument splats across $0/$1/… when the body
            // references $1 (enumerated().forEach { … $0 … $1 … }); a
            // $0-only body keeps the whole tuple in $0.
            if values.count == 1, let tuple = values[0].tupleValue, tuple.values.count > 1,
               ShorthandTupleScanner.splats(closure.body) {
                for (index, element) in tuple.values.enumerated() {
                    env.define("$\(index)", element)
                }
                return []
            }
            for (index, value) in values.enumerated() {
                env.define("$\(index)", value)
            }
            return []
        }

        // `{ index, char in … }` over enumerated() — one tuple argument
        // splats across multiple parameters.
        if closure.parameters.count > 1, args.arguments.count == 1,
           let tuple = args.arguments[0].value.tupleValue,
            tuple.values.count == closure.parameters.count {
            for (parameter, value) in zip(closure.parameters, tuple.values) {
                env.define(
                    parameter.name,
                    try resolveAnnotated(value, parameter: parameter),
                    declaredTypeName: parameter.typeName)
            }
            return []
        }

        var labeled: [String: RuntimeValue] = [:]
        var positionals: [RuntimeValue] = []
        var unlabeledTrailing: [RuntimeValue] = []
        for argument in args.arguments {
            if let label = argument.label {
                labeled[label] = argument.value
            } else if argument.isTrailing {
                unlabeledTrailing.append(argument.value)
            } else {
                positionals.append(argument.value)
            }
        }

        var bound = [RuntimeValue?](repeating: nil, count: closure.parameters.count)
        var positionalCursor = 0
        for (index, parameter) in closure.parameters.enumerated() {
            if parameter.isVariadic {
                // `arguments: CVarArg...` — the labeled value (Swift labels
                // only the first) plus every remaining positional; absent
                // means empty, never a binding error.
                var gathered: [RuntimeValue] = []
                if let label = parameter.label, let value = labeled.removeValue(forKey: label) {
                    gathered.append(value)
                    gathered.append(contentsOf: positionals[positionalCursor...])
                    positionalCursor = positionals.count
                } else if parameter.label == nil {
                    gathered.append(contentsOf: positionals[positionalCursor...])
                    positionalCursor = positionals.count
                }
                // Each element resolves against the ELEMENT annotation —
                // implicit members contextually type exactly like
                // non-variadic arguments (TestStore.assert(_ steps: Step…)
                // receiving `.send(action) { … }` factories).
                gathered = try gathered.map { try resolveAnnotated($0, parameter: parameter) }
                bound[index] = .native(gathered)
                continue
            }
            if let label = parameter.label, let value = labeled.removeValue(forKey: label) {
                bound[index] = value
            } else if parameter.label == nil, positionalCursor < positionals.count {
                bound[index] = positionals[positionalCursor]
                positionalCursor += 1
            }
        }
        // Leftover positionals fill remaining unbound params in order (calls
        // that pass labeled params positionally — a tolerated looseness).
        for (index, value) in zip(bound.indices.filter({ bound[$0] == nil }), positionals[positionalCursor...]) {
            bound[index] = value
        }
        // The unlabeled trailing closure binds by SE-0286 forward scan:
        // the FIRST unbound function-typed parameter
        // (`getNavigationView { … }` fills `content:` even when defaulted
        // Bools follow); falling back to the last unbound slot when no
        // annotation is function-shaped.
        for trailing in unlabeledTrailing.reversed() {
            let accepts: (Int) -> Bool = { index in
                let parameter = closure.parameters[index]
                return parameter.isBuilderAttributed
                    || parameter.typeAnnotation?.trimmedDescription.contains("->") == true
            }
            if let index = bound.indices.first(where: { bound[$0] == nil && accepts($0) }) {
                bound[index] = trailing
            } else if let index = bound.indices.last(where: { bound[$0] == nil }) {
                bound[index] = trailing
            }
        }

        var writeBacks: [(name: String, slot: InoutSlot)] = []
        for (index, parameter) in closure.parameters.enumerated() {
            if let value = bound[index] {
                // `inout` argument: alias the caller's box when the argument
                // was a plain variable; otherwise copy in and register the
                // lvalue for copy-out on return.
                if let slot = value.inoutSlot {
                    if let box = slot.box {
                        env.define(parameter.name, sharing: box)
                    } else {
                        env.define(
                            parameter.name, slot.current,
                            declaredTypeName: parameter.typeName)
                        writeBacks.append((parameter.name, slot))
                    }
                    continue
                }
                var resolved = try resolveAnnotated(value, parameter: parameter)
                // The result-builder transform: a closure bound to a
                // @…Builder parameter collects its block's items when
                // called instead of returning the last expression.
                if parameter.isBuilderAttributed, case .closure(let c) = resolved, !c.isBuilder {
                    resolved = .closure(ClosureValue(
                        parameters: c.parameters, body: c.body, captured: c.captured,
                        isBuilder: true,
                        returnType: parameter.builderReturnType ?? c.returnType,
                        returnTypeName: parameter.builderReturnTypeName ?? c.returnTypeName
                    ))
                }
                env.define(
                    parameter.name, resolved,
                    declaredTypeName: parameter.typeName)
                // `{ $item in … }` — the binding parameter also exposes its
                // wrapped value: `item` shares the binding's box, so reads
                // are live and writes propagate.
                if parameter.name.hasPrefix("$"), parameter.name.count > 1,
                   case .host(let any) = resolved, let stub = any as? BindingStub {
                    env.define(String(parameter.name.dropFirst()), sharing: stub.box)
                }
            } else if let defaultValue = parameter.defaultValue {
                env.define(
                    parameter.name,
                    try resolveAnnotated(
                        try evaluate(defaultValue, in: closure.captured),
                        parameter: parameter),
                    declaredTypeName: parameter.typeName)
            } else if let node {
                throw error(node, "missing argument for parameter '\(parameter.name)'")
            } else {
                throw RuntimeError(message: "missing argument for parameter '\(parameter.name)'")
            }
        }
        return writeBacks
    }
}
