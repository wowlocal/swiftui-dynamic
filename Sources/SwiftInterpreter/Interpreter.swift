import Foundation
import SwiftSyntax
import SwiftParser
import SwiftOperators
import SwiftParserDiagnostics

/// The public facade: parse → fold operators → collect declarations → evaluate.
///
/// A tree-walking interpreter over SwiftSyntax ASTs. It implements no
/// framework functionality itself; anything beyond core language semantics is
/// delegated to a `HostRegistry` (the SwiftUI bridge, or a trace registry in
/// tests).
public final class Interpreter {
    public let globals = Environment()
    public var registry: HostRegistry?
    /// Struct symbols in declaration order (used to pick the root View).
    public internal(set) var structSymbols: [StructSymbol] = []
    var enumSymbols: [String: EnumSymbol] = [:]
    /// Env-object models constructed as fresh-store stand-ins (one per type,
    /// so every view reading the type sees the same instance).
    var synthesizedEnvironmentModels: [String: Instance] = [:]
    /// Interpreted `extension View { … }` / `extension String { … }` members,
    /// keyed by the extended host type's name.
    var hostExtensionSymbols: [String: StructSymbol] = [:]

    var locationConverter: SourceLocationConverter?
    var steps = 0
    /// Guards against `while true {}` freezing the UI: evaluation is main-actor.
    let stepBudget = 100_000
    /// Guards against runaway interpreted recursion overflowing the NATIVE
    /// stack (each interpreted call is ~10 Swift frames) before the step
    /// budget can trip. Fatal — never catchable by interpreted code.
    var callDepth = 0
    let callDepthLimit = 200

    public init(registry: HostRegistry? = nil) {
        self.registry = registry
        defineGlobalBuiltins()
    }

    // MARK: - Parsing

    public func parse(source: String) throws -> SourceFileSyntax {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "input.swift", tree: tree)
        locationConverter = converter

        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        if let firstError = diagnostics.first(where: { $0.diagMessage.severity == .error }) {
            let location = converter.location(for: firstError.position)
            throw RuntimeError(message: firstError.message, line: location.line, column: location.column)
        }

        var operatorErrors: [OperatorError] = []
        // User-declared operators and precedence groups (Point-Free's
        // `|>` pipe) join the fold table; conflicts with the standard set
        // are tolerated (last declaration wins inside addSourceFile).
        var table = OperatorTable.standardOperators
        try? table.addSourceFile(tree) { _ in }
        let folded = table.foldAll(tree) { operatorErrors.append($0) }
        if let first = operatorErrors.first(where: {
            // Operators declared in EXTERNAL modules (Overture's `|>`)
            // recover with default precedence — the evaluator gives them
            // meaning (or absorbs). Other fold errors stay fatal.
            if case .missingOperator = $0 { return false }
            return true
        }) {
            throw RuntimeError(message: "operator error: \(first)", line: 1, column: 1)
        }
        guard let foldedFile = folded.as(SourceFileSyntax.self) else {
            throw RuntimeError(message: "internal error: operator folding failed", line: 1, column: 1)
        }
        return foldedFile
    }

    // MARK: - Running programs

    /// Parse and run a whole program: type/function declarations are hoisted,
    /// then top-level statements execute in order. Returns the value of the
    /// last top-level expression (handy for tests and for `ContentView()` as
    /// an explicit root).
    @discardableResult
    public func run(source: String) throws -> RuntimeValue {
        let file = try parse(source: source)
        steps = 0
        try collectDeclarations(from: file)

        var last: RuntimeValue = .void
        for item in expandedTopLevelItems(file.statements) {
            if case .decl(let decl) = item.item,
               decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self)
                || decl.is(ActorDeclSyntax.self) || decl.is(ImportDeclSyntax.self)
                || decl.is(FunctionDeclSyntax.self) || decl.is(ProtocolDeclSyntax.self)
                || decl.is(OperatorDeclSyntax.self) || decl.is(PrecedenceGroupDeclSyntax.self)
                || decl.is(TypeAliasDeclSyntax.self)
                || decl.is(EnumDeclSyntax.self) || decl.is(ExtensionDeclSyntax.self) {
                continue // already collected (protocols: requirements carry
                // no bodies; defaults live in their extensions)
            }
            if case .decl(let decl) = item.item,
               let varDecl = decl.as(VariableDeclSyntax.self), isHoistableGlobal(varDecl) {
                // Hoisted as lazy for FORWARD references; still executed
                // eagerly in statement order (main.swift semantics) unless a
                // forward reference already forced it — then re-running would
                // clobber mutations and repeat side effects.
                let alreadyForced = varDecl.bindings.contains { binding in
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                          let box = globals.box(for: ident.identifier.text) else { return false }
                    if case .native(let any) = box.value, any is LazyGlobal { return false }
                    return true
                }
                if alreadyForced { continue }
            }
            let result = try execute(item, in: globals)
            switch result {
            case .normal(let value):
                last = value
            case .returnValue(let value):
                return value
            case .breakLoop, .continueLoop:
                throw RuntimeError(message: "break/continue outside a loop", line: 1, column: 1)
            }
        }
        return last
    }

    // MARK: - Instances

    /// A builder-attributed stored property builds from its trailing closure:
    /// `[X]`-annotated properties collect the block's items into an ARRAY
    /// (custom @resultBuilders' buildBlock), view-typed ones group as views.
    func builderValue(for property: StructSymbol.StoredProperty, closure: ClosureValue) throws -> RuntimeValue {
        let items = try callBuilderClosure(closure, arguments: [])
        let annotation = property.typeAnnotation?.trimmedDescription ?? ""
        if annotation.hasPrefix("[") {
            return .native(items)
        }
        return try groupViews(items)
    }


    /// Custom `init`s run with `self` bound to a defaults-initialized instance;
    /// otherwise default + memberwise initialization applies. `$binding`
    /// arguments for `@Binding` properties share the parent's Box.
    public func instantiate(_ symbol: StructSymbol, with args: CallArguments, node: Syntax? = nil) throws -> RuntimeValue {
        let instance = Instance(symbol: symbol)
        let notifying = Set(symbol.notifyingPropertyNames)
        for property in symbol.storedProperties {
            // Optional-typed properties without initializers are nil in Swift.
            let annotationText = property.typeAnnotation?.trimmedDescription ?? ""
            var value: RuntimeValue = annotationText.hasSuffix("?") || annotationText.hasSuffix("!")
                ? .nilValue : .void
            if let initializer = property.initializer {
                // Static context: property initializers may reference the
                // type's own statics bare (`= Timer.publish(every:
                // autoScrollDuration, …)`).
                value = try resolveAnnotated(
                    try evaluate(initializer, in: selfEnvironment(.type(symbol))),
                    annotation: property.typeAnnotation
                )
            }
            let box = Box(value)
            if notifying.contains(property.name) {
                // @Published (or @Observable-tracked) mutation → model signal.
                let signal = instance.changeSignal
                box.onChange = { signal.fire() }
            }
            switch property.wrapper {
            case .state, .stateObject:
                instance.stateBoxes[property.name] = box
            default:
                instance.properties[property.name] = box
            }
        }

        if symbol.initializers.isEmpty {
            var assigned = Set<String>()
            // Labeled arguments claim their properties FIRST, so an unlabeled
            // trailing closure can't steal a property that a later labeled
            // trailing names (`CustomButton(tint:) { content } action: {…}`).
            for argument in args.arguments {
                guard let label = argument.label else { continue }
                guard let property = symbol.storedProperty(named: label),
                      let box = instance.box(for: label) else {
                    // Host-superclass classes (class RainFall: SKScene)
                    // inherit their initializers: unmatched labeled
                    // arguments bind as properties so later reads
                    // (`size` in sceneDidLoad) see the passed values.
                    if let superName = symbol.superclassName, !isInterpretedType(superName) {
                        instance.properties[label] = Box(argument.value)
                        assigned.insert(label)
                        continue
                    }
                    let message = "argument '\(label)' doesn't match a stored property of '\(symbol.name)'"
                    if let node { throw error(node, message) }
                    throw RuntimeError(message: message)
                }
                assigned.insert(label)
                if property.wrapper == .binding,
                   case .native(let any) = argument.value, let stub = any as? BindingStub {
                    instance.properties[label] = stub.box
                } else if property.wrapper == .binding,
                          case .native(let any) = argument.value,
                          let call = any as? ImplicitMemberCall, call.name == "constant" {
                    // `.constant("")` — a binding to a fixed value.
                    instance.properties[label] = Box(try resolveAnnotated(
                        call.arguments.positional(0) ?? .void,
                        annotation: property.typeAnnotation))
                } else if let closure = argument.value.closureValue,
                          property.isBuilderClosure,
                          !(property.typeAnnotation?.trimmedDescription.contains("->") ?? false) {
                    // Labeled trailing onto a builder property.
                    box.value = try builderValue(for: property, closure: closure)
                } else {
                    box.value = try resolveAnnotated(argument.value, annotation: property.typeAnnotation)
                }
            }
            for argument in args.arguments where argument.label == nil {
                if argument.value.closureValue != nil {
                    // Unlabeled trailing closure → FIRST unassigned
                    // closure-shaped stored property (SE-0286 forward scan);
                    // @ViewBuilder properties store the BUILT view (matching
                    // Swift's synthesized memberwise + builder init).
                    // `TagLayout(spacing: 10) { … }` — Layout containers
                    // take trailing content; children stash for rendering
                    // (the custom layout math doesn't run — documented).
                    if symbol.conformsToLayout,
                       !symbol.storedProperties.contains(where: { !assigned.contains($0.name) && $0.acceptsTrailingClosure }) {
                        let closure = argument.value.closureValue!
                        let children = try callBuilderClosure(closure, arguments: [])
                        instance.properties[StructSymbol.layoutChildrenKey] = Box(.native(children))
                        continue
                    }
                    guard let property = symbol.storedProperties.first(where: {
                        !assigned.contains($0.name) && $0.acceptsTrailingClosure
                    }), let box = instance.box(for: property.name) else {
                        let message = "trailing closure doesn't match a closure property of '\(symbol.name)'"
                        if let node { throw error(node, message) }
                        throw RuntimeError(message: message)
                    }
                    assigned.insert(property.name)
                    let functionTyped = property.typeAnnotation?.trimmedDescription.contains("->") ?? false
                    if property.isBuilderClosure && !functionTyped {
                        // Builder property — build now (array or grouped views).
                        let closure = argument.value.closureValue!
                        box.value = try builderValue(for: property, closure: closure)
                    } else {
                        // `var content: (CGSize) -> Content` (builder or not) —
                        // store the closure; the body calls it with arguments.
                        box.value = argument.value
                    }
                } else {
                    let message = "argument '_' doesn't match a stored property of '\(symbol.name)'"
                    if let node { throw error(node, message) }
                    throw RuntimeError(message: message)
                }
            }
        } else {
            return try runInitializer(
                chooseInitializer(from: symbol.initializers, for: args),
                on: instance, args: args, node: node)
        }
        return .instance(instance)
    }

    /// Run one initializer body with `self` bound to the instance — used
    /// by instantiate and by `self.init(…)` delegation. Returns the FINAL
    /// self: struct inits may reassign it (`self = decoded`), and the
    /// caller must hand back that value, not the seed instance.
    @discardableResult
    func runInitializer(
        _ chosen: InitializerDeclSyntax, on instance: Instance,
        args: CallArguments, node: Syntax?
    ) throws -> RuntimeValue {
        guard let body = chosen.body else {
            throw RuntimeError(message: "init of '\(instance.symbol.name)' has no body")
        }
        let parameters = chosen.signature.parameterClause.parameters.map { param in
            ClosureValue.Parameter(
                name: (param.secondName ?? param.firstName).text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                label: param.firstName.text == "_" ? nil : param.firstName.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                defaultValue: param.defaultValue?.value,
                typeAnnotation: param.type,
                isBuilderAttributed: param.attributes.contains {
                    $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
                } || ClosureValue.Parameter.isBuilderAttributedType(param.type)
            )
        }
        let initEnv = selfEnvironment(.instance(instance))
        let closure = ClosureValue(
            parameters: parameters,
            body: body.statements,
            captured: initEnv
        )
        let outcome = try callWithArguments(closure, args: args, node: node)
        if chosen.optionalMark != nil, outcome.isNil {
            return .nilValue // failable init: `return nil` means NO value
        }
        if case .instance(let final)? = initEnv.lookup("self"), final !== instance {
            return .instance(final) // `self = other` reassigned the value
        }
        return .instance(instance)
    }

    func chooseInitializer(from initializers: [InitializerDeclSyntax], for args: CallArguments) -> InitializerDeclSyntax {
        let argLabels = args.arguments.compactMap(\.label)
        for candidate in initializers {
            let params = candidate.signature.parameterClause.parameters
            let labels = params.map { $0.firstName.text }
            if args.arguments.count <= params.count, argLabels.allSatisfy({ labels.contains($0) }) {
                return candidate
            }
        }
        return initializers[0]
    }

    /// Evaluate an instance's `body` computed property in ViewBuilder mode.
    /// Multiple top-level views are grouped by the registry (TupleView stand-in).
    public func evaluateBody(of instance: Instance) throws -> RuntimeValue {
        steps = 0
        guard let computed = instance.symbol.computedProperties["body"] else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no body property")
        }
        let views = try collectBuilderViews(computed.accessor, in: selfEnvironment(.instance(instance)))
        return try groupViews(views)
    }

    /// Call an instance method with positional arguments — the bridge's entry
    /// point for protocol requirements it hosts (a Shape's `path(in:)`).
    public func callMethod(named name: String, on instance: Instance, arguments: [RuntimeValue]) throws -> RuntimeValue {
        guard let member = try instanceMember(name, on: instance),
              let closure = member.closureValue else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no method '\(name)'")
        }
        return try callClosure(closure, arguments: arguments)
    }

    /// Fill `@EnvironmentObject` properties from ambient models (keyed by type
    /// name). The SwiftUI bridge reads the models off the real Environment;
    /// headless harnesses thread them down the trace tree. When no ambient
    /// model exists (the App shell that would inject it never runs), a fresh
    /// instance of the type is synthesized once and reused — the same
    /// fresh-store doctrine as @Query.
    public func injectEnvironmentObjects(into instance: Instance, models: [String: Instance]) throws {
        for property in instance.symbol.storedProperties where property.wrapper == .environmentObject {
            let typeName = property.typeAnnotation?.trimmedDescription ?? ""
            let model: Instance
            if let ambient = models[typeName] {
                model = ambient
            } else if let synthesized = synthesizedEnvironmentModels[typeName] {
                model = synthesized
            } else if case .type(let symbol)? = globals.lookup(typeName),
                      case .instance(let fresh) = try instantiateRoot(symbol) {
                // Fresh model with FRESH parameter values — the same
                // synthesis roots get (inits with required params work).
                synthesizedEnvironmentModels[typeName] = fresh
                model = fresh
            } else {
                throw RuntimeError(message: "no ObservableObject of type '\(typeName)' in the environment — inject it with .environmentObject(_:)")
            }
            instance.box(for: property.name)?.value = .instance(model)
        }
    }

    /// Fill `@Environment(\.key)` properties from a key→value table (the
    /// bridge reads real values off SwiftUI's Environment; headless harnesses
    /// inject honest defaults). Unknown keys are left untouched.
    public func injectEnvironmentValues(into instance: Instance, values: [String: RuntimeValue]) {
        for property in instance.symbol.storedProperties {
            guard case .environment(let key) = property.wrapper else { continue }
            if let value = values[key] {
                instance.box(for: property.name)?.value = value
                continue
            }
            // CUSTOM environment keys (extension EnvironmentValues { @Entry
            // var indentationLevel: UInt = 0 }): read the extension's OWN
            // declared default when present; otherwise the fresh identity
            // of the annotation (false/0/""/nil) — the fresh-canvas reading.
            if let box = instance.box(for: property.name), case .void = box.value {
                if let envExtension = hostExtensionSymbols["EnvironmentValues"],
                   let declared = envExtension.storedProperty(named: key),
                   let initializer = declared.initializer,
                   let value = try? evaluate(initializer, in: globals) {
                    box.value = (try? resolveAnnotated(value, annotation: declared.typeAnnotation)) ?? value
                    continue
                }
                let typeName = property.typeAnnotation?.trimmedDescription ?? ""
                var seen: Set<String> = []
                box.value = (try? synthesizedFreshValue(typeName: typeName, seen: &seen)) ?? .nilValue
            }
        }
    }

    /// The struct to render when the program doesn't end in an explicit view
    /// expression: `ContentView` if present, then `Main`, then the first
    /// View-conforming struct in declaration order.
    /// Instantiate a root view for standalone verification: required
    /// parameters (un-defaulted stored properties, or a custom init's
    /// parameters) receive synthesized FRESH values — the fresh-state
    /// doctrine applied to view parameters.
    public func instantiateRoot(_ symbol: StructSymbol) throws -> RuntimeValue {
        var seen: Set<String> = [symbol.name]
        let args = try synthesizedArguments(for: symbol, seen: &seen)
        return try instantiate(symbol, with: args)
    }

    private func synthesizedArguments(for symbol: StructSymbol, seen: inout Set<String>) throws -> CallArguments {
        var arguments: [CallArguments.Argument] = []
        // Prefer a NON-failable init: synthesized fresh arguments rarely
        // satisfy `init?` guards (hex parsing etc.), and nil poisons roots.
        let preferred = symbol.initializers.first { $0.optionalMark == nil }
            ?? symbol.initializers.first
        if let initializer = preferred {
            for param in initializer.signature.parameterClause.parameters
            where param.defaultValue == nil {
                let label = param.firstName.text
                let value = try synthesizedFreshValue(
                    typeName: param.type.trimmedDescription, seen: &seen)
                arguments.append(.init(label: label == "_" ? nil : label, value: value))
            }
        } else {
            for property in symbol.storedProperties
            where property.initializer == nil && !property.isBuilderClosure {
                let typeName = property.typeAnnotation?.trimmedDescription ?? ""
                switch property.wrapper {
                case .none:
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: typeName, seen: &seen)))
                case .binding:
                    // A standalone root has no parent to pass bindings —
                    // synthesize one over the inner type's fresh value.
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: "Binding<\(typeName)>", seen: &seen)))
                case .observedObject:
                    // Fresh model per the missing-environment-object doctrine.
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: typeName, seen: &seen)))
                default:
                    break // @State/@StateObject etc. default independently
                }
            }
        }
        return CallArguments(arguments: arguments)
    }

    /// The fresh value of a type: identity for primitives, empty for
    /// collections, nil for optionals, recursive fresh instances for
    /// interpreted types, and an unknowable chain (absorbs everywhere)
    /// for host/generic types.
    func synthesizedFreshValue(typeName rawName: String, seen: inout Set<String>) throws -> RuntimeValue {
        var typeName = rawName.trimmingCharacters(in: .whitespaces)
        if typeName.hasSuffix("?") || typeName.hasSuffix("!") { return .nilValue }
        if typeName.hasPrefix("[") { // arrays AND dictionaries start empty
            return typeName.contains(":") ? .native(DictValue()) : .native([RuntimeValue]())
        }
        if typeName.contains("->") {
            return .hostFunction(HostFunction(name: "synthesized") { _, _ in .void })
        }
        if typeName.hasPrefix("Binding<"), typeName.hasSuffix(">") {
            let inner = String(typeName.dropFirst("Binding<".count).dropLast())
            let value = try synthesizedFreshValue(typeName: inner, seen: &seen)
            return .native(BindingStub(box: Box(value)))
        }
        switch typeName {
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8",
             "UInt16", "UInt32", "UInt64": return .native(0)
        case "String", "Character": return .native("")
        case "Bool": return .native(false)
        case "Date": return .native(Date())
        case "Data": return .native(Data())
        default: break
        }
        if Self.doubleFamilyTypeNames.contains(typeName) { return .native(0.0) }
        if let generic = typeName.firstIndex(of: "<") {
            typeName = String(typeName[..<generic]) // Store<A, B> → Store
        }
        if !seen.contains(typeName) {
            seen.insert(typeName)
            defer { seen.remove(typeName) }
            if case .type(let nested)? = globals.lookup(typeName) {
                let args = try synthesizedArguments(for: nested, seen: &seen)
                return try instantiate(nested, with: args)
            }
            if let enumSymbol = enumSymbols[typeName],
               let first = enumSymbol.cases.first(where: { !$0.hasAssociatedValues }) {
                return .enumCase(EnumCaseValue(symbol: enumSymbol, name: first.name))
            }
        }
        // Host/generic/cyclic types: an unknowable chain — reads chain,
        // bools read false, numerics zero, iteration empty.
        return .native(ChainedImplicitCall(
            base: .implicitMember("synthesized"), member: typeName, arguments: CallArguments()))
    }

    public func rootViewSymbol() -> StructSymbol? {
        let candidates = structSymbols.filter(\.conformsToView)
        return candidates.first { $0.name == "ContentView" }
            ?? candidates.first { $0.name == "Main" }
            ?? candidates.first
    }

    /// Whether a name resolves to an interpreted struct/class/enum symbol
    /// (as opposed to a host framework type like SKScene).
    func isInterpretedType(_ name: String) -> Bool {
        if case .type? = globals.lookup(name) { return true }
        if case .enumType? = globals.lookup(name) { return true }
        return false
    }

    static let doubleFamilyTypeNames: Set<String> = [
        "Double", "CGFloat", "Float", "TimeInterval", "Float32", "Float64",
    ]

    func selfEnvironment(_ selfValue: RuntimeValue) -> Environment {
        let env = Environment(parent: globals)
        env.define("self", selfValue)
        return env
    }

    /// A type annotation turns a bare `.member` (or `.member(payload)`) into
    /// the annotated type's case, `.init`, or static member — the dynamic
    /// stand-in for type context. `[Type]` annotations resolve array elements.
    func resolveAnnotated(_ value: RuntimeValue, annotation: TypeSyntax?) throws -> RuntimeValue {
        guard let annotation else { return value }
        return try resolveAnnotated(value, typeName: annotation.trimmedDescription)
    }

    func resolveAnnotated(_ value: RuntimeValue, typeName rawName: String) throws -> RuntimeValue {
        var typeName = rawName.trimmingCharacters(in: .whitespaces)
        if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }

        // Double-family storage holds doubles: `var offset: CGFloat = 0`
        // stores 0.0, so division/interpolation behave like compiled Swift
        // (20 / offset is IEEE infinity, not an Int-division trap).
        if Self.doubleFamilyTypeNames.contains(typeName), let i = value.intValue {
            return .native(Double(i))
        }

        // `[Item]` — resolve each element against the element type.
        if typeName.hasPrefix("["), typeName.hasSuffix("]"), !typeName.contains(":"),
           let array = value.arrayValue {
            let elementType = String(typeName.dropFirst().dropLast())
            return .native(try array.map { try resolveAnnotated($0, typeName: elementType) })
        }

        if let symbol = enumSymbols[typeName] {
            if case .implicitMember(let name) = value,
               let info = symbol.caseInfo(named: name), !info.hasAssociatedValues {
                return .enumCase(EnumCaseValue(symbol: symbol, name: name))
            }
            // `self = .init(rawValue: n)!` inside enum inits — the marker
            // resolves through the raw-value initializer in type context.
            if case .native(let any) = value, let call = any as? ImplicitMemberCall,
               call.name == "init", call.arguments.arguments.count == 1,
               let raw = call.arguments.labeled("rawValue") {
                return symbol.cases
                    .first { (try? Builtins.areEqual($0.rawValue, raw)) == true }
                    .map { RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name)) }
                    ?? .nilValue
            }
            if case .native(let any) = value, let call = any as? ImplicitMemberCall,
               let info = symbol.caseInfo(named: call.name), info.hasAssociatedValues {
                return .enumCase(EnumCaseValue(
                    symbol: symbol,
                    name: call.name,
                    associated: call.arguments.arguments.map(\.value)
                ))
            }
            return value
        }

        // User structs/classes: `= .init(...)`, static factories, static values.
        if case .type(let symbol)? = globals.lookup(typeName) {
            if case .native(let any) = value, let call = any as? ImplicitMemberCall {
                if call.name == "init" {
                    return try instantiate(symbol, with: call.arguments)
                }
                if let method = symbol.staticMethods[call.name], let body = method.body {
                    let closure = makeFunctionClosure(method, body: body, captured: globals)
                    return try callWithArguments(closure, args: call.arguments, node: nil)
                }
            }
            if case .implicitMember(let name) = value,
               let staticValue = try staticMember(name, of: symbol) {
                return staticValue
            }
            return value
        }

        // Host-type annotations: `: Date = .init()`, `: CGSize = .init(…)`,
        // `.now`-style statics served by the bridge.
        if case .native(let any) = value, let call = any as? ImplicitMemberCall {
            if call.name == "init" {
                if let ctor = registry?.hostObjectConstructor(named: typeName) {
                    return try ctor.invoke(call.arguments, self)
                }
                if case .hostFunction(let builtin)? = globals.lookup(typeName) {
                    return try builtin.invoke(call.arguments, self)
                }
            }
            if let member = registry?.hostMember(call.name, on: HostTypeMarker(name: typeName)) {
                if case .hostFunction(let function) = member {
                    return try function.invoke(call.arguments, self)
                }
                return member
            }
        }
        if case .implicitMember(let memberName) = value,
           let member = registry?.hostMember(memberName, on: HostTypeMarker(name: typeName)) {
            return member
        }
        // `.now.startOfMonth` — chained markers resolve their base against
        // the type, then the member (host natives and user extensions both).
        if case .native(let any) = value, let chained = any as? ChainedImplicitCall {
            let resolvedBase = try resolveAnnotated(chained.base, typeName: typeName)
            let stillMarker: Bool = {
                if case .implicitMember = resolvedBase { return true }
                if case .native(let inner) = resolvedBase,
                   inner is ImplicitMemberCall || inner is ChainedImplicitCall { return true }
                return false
            }()
            if !stillMarker {
                let anchor = ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier("resolvedChainBase")))
                let member = try accessMember(chained.member, on: resolvedBase, node: anchor, env: globals)
                switch member {
                case .closure(let closure):
                    return try callWithArguments(closure, args: chained.arguments, node: nil)
                case .hostFunction(let function):
                    return try function.invoke(chained.arguments, self)
                default:
                    return member
                }
            }
        }

        // User extensions of host types add statics too:
        // `extension Date { static var currentMonth: Date }` resolves
        // `: Date = .currentMonth` (and `.createDate(…)` factories).
        if let hostSymbol = hostExtensionSymbols[typeName] {
            if case .implicitMember(let memberName) = value,
               let staticValue = try staticMember(memberName, of: hostSymbol) {
                return staticValue
            }
            if case .native(let any) = value, let call = any as? ImplicitMemberCall,
               let method = hostSymbol.staticMethods[call.name], let body = method.body {
                let closure = makeFunctionClosure(method, body: body, captured: globals)
                return try callWithArguments(closure, args: call.arguments, node: nil)
            }
        }
        return value
    }

    // MARK: - Global builtins

    private func defineGlobalBuiltins() {
        func define(_ name: String, _ invoke: @escaping @MainActor (CallArguments, EvalContext) throws -> RuntimeValue) {
            globals.define(name, .hostFunction(HostFunction(name: name, invoke: invoke)))
        }
        define("print") { args, _ in
            Swift.print(args.arguments.map { $0.value.stringValue ?? $0.value.stringified }.joined(separator: " "))
            return .void
        }
        define("abs") { args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: "abs needs a number") }
            if let i = value.intValue { return .native(Swift.abs(i)) }
            if let d = value.doubleValue { return .native(Swift.abs(d)) }
            throw RuntimeError(message: "abs needs a number")
        }
        func defineUnaryMath(_ name: String, _ op: @escaping (Double) -> Double) {
            define(name) { args, _ in
                guard let d = args.positional(0)?.doubleValue else {
                    throw RuntimeError(message: "\(name) needs a number")
                }
                return .native(op(d))
            }
        }
        defineUnaryMath("round") { $0.rounded() }
        defineUnaryMath("floor") { $0.rounded(.down) }
        defineUnaryMath("ceil") { $0.rounded(.up) }
        defineUnaryMath("sqrt") { $0.squareRoot() }
        defineUnaryMath("sin") { Foundation.sin($0) }
        defineUnaryMath("cos") { Foundation.cos($0) }
        defineUnaryMath("tan") { Foundation.tan($0) }
        defineUnaryMath("asin") { Foundation.asin($0) }
        defineUnaryMath("acos") { Foundation.acos($0) }
        defineUnaryMath("atan") { Foundation.atan($0) }
        defineUnaryMath("log") { Foundation.log($0) }
        defineUnaryMath("log2") { Foundation.log2($0) }
        defineUnaryMath("exp") { Foundation.exp($0) }
        define("atan2") { args, _ in
            guard let y = args.positional(0)?.doubleValue, let x = args.positional(1)?.doubleValue else {
                throw RuntimeError(message: "atan2 needs two numbers")
            }
            return .native(Foundation.atan2(y, x))
        }
        define("hypot") { args, _ in
            guard let x = args.positional(0)?.doubleValue, let y = args.positional(1)?.doubleValue else {
                throw RuntimeError(message: "hypot needs two numbers")
            }
            return .native(Foundation.hypot(x, y))
        }
        define("pow") { args, _ in
            guard let base = args.positional(0)?.doubleValue, let exponent = args.positional(1)?.doubleValue else {
                throw RuntimeError(message: "pow needs two numbers")
            }
            return .native(Foundation.pow(base, exponent))
        }
        define("min") { args, _ in
            try Self.extremum(args, op: "<")
        }
        define("max") { args, _ in
            try Self.extremum(args, op: ">")
        }
        define("String") { args, _ in
            if let format = args.labeled("format")?.stringValue {
                // `String(format: "%.1f", per)` — real formatting; remaining
                // positionals map to CVarArgs.
                let varargs: [CVarArg] = args.arguments.dropFirst().compactMap { argument in
                    if let i = argument.value.intValue { return i }
                    if let d = argument.value.doubleValue { return d }
                    if let s = argument.value.stringValue { return s }
                    return nil
                }
                return .native(Swift.String(format: format, arguments: varargs))
            }
            if let repeating = args.labeled("repeating")?.stringValue, let count = args.labeled("count")?.intValue {
                return .native(Swift.String(repeating: repeating, count: Swift.max(0, count)))
            }
            guard let value = args.positional(0) ?? args.labeled("describing") else { return .native("") }
            return .native(value.stringValue ?? value.stringified)
        }
        define("Int") { args, _ in
            guard let value = args.positional(0) else { return .nilValue }
            if let i = value.intValue { return .native(i) }
            if let d = value.doubleValue { return .native(Int(d)) }
            if let s = value.stringValue { return Int(s).map { RuntimeValue.native($0) } ?? .nilValue }
            // Numeric conversion of an unknowable reads the fresh state —
            // Int(player.currentTime.truncatingRemainder(…)) is 0, not nil.
            if let z = Builtins.absorbedNumeric(value) { return .native(Int(z.isFinite ? z : 0)) }
            return .nilValue
        }
        define("Double") { args, _ in
            guard let value = args.positional(0) else { return .nilValue }
            if let d = value.doubleValue { return .native(d) }
            if let s = value.stringValue { return Double(s).map { RuntimeValue.native($0) } ?? .nilValue }
            if let z = Builtins.absorbedNumeric(value) { return .native(z) }
            return .nilValue
        }
        define("Float") { args, _ in
            // Our floating model is Double throughout.
            guard let value = args.positional(0) else { return .nilValue }
            if let d = value.doubleValue { return .native(d) }
            if let s = value.stringValue { return Double(s).map { RuntimeValue.native($0) } ?? .nilValue }
            if let z = Builtins.absorbedNumeric(value) { return .native(z) }
            return .nilValue
        }
        define("CGFloat") { args, _ in
            // Our CGFloat model IS Double.
            guard let d = args.positional(0)?.doubleValue else {
                throw RuntimeError(message: "CGFloat needs a number")
            }
            return .native(d)
        }
        define("Array") { args, _ in
            if let element = args.labeled("repeating"), let count = args.labeled("count")?.intValue {
                return .native([RuntimeValue](repeating: element, count: max(0, count)))
            }
            guard let value = args.positional(0) else { return .native([RuntimeValue]()) }
            if let range = value.rangeValue { return .native(range.map { RuntimeValue.native($0) }) }
            if let array = value.arrayValue { return .native(array) }
            // Array("abc") splits into characters (single-char strings,
            // our character model): Array(constant)[i] indexes real chars.
            if let s = value.stringValue {
                return .native(s.map { RuntimeValue.native(String($0)) })
            }
            return .native([value])
        }
        define("Set") { args, _ in
            // Array-backed set-lite: construction and iteration cover the
            // corpus (Set<AnyCancellable>() holders, Set(array) dedup-ish).
            if let array = args.positional(0)?.arrayValue {
                var seen: [RuntimeValue] = []
                for element in array where try !seen.contains(where: { try Builtins.areEqual($0, element) }) {
                    seen.append(element)
                }
                return .native(seen)
            }
            return .native([RuntimeValue]())
        }
        define("fatalError") { args, _ in
            let message = args.positional(0)?.stringValue ?? "fatalError"
            throw RuntimeError(message: "fatalError: \(message)", fatal: true)
        }
        define("preconditionFailure") { args, _ in
            let message = args.positional(0)?.stringValue ?? "preconditionFailure"
            throw RuntimeError(message: "preconditionFailure: \(message)", fatal: true)
        }
        define("assertionFailure") { args, _ in
            let message = args.positional(0)?.stringValue ?? "assertionFailure"
            throw RuntimeError(message: "assertionFailure: \(message)", fatal: true)
        }
        // assert/precondition describe DEVICE truths: concrete false traps,
        // unknowable (marker-fed) conditions assume a healthy device.
        for trap in ["assert", "precondition"] {
            define(trap) { args, _ in
                if case .native(let flag)? = args.positional(0), let concrete = flag as? Bool,
                   !concrete {
                    let message = args.positional(1)?.stringValue ?? trap
                    throw RuntimeError(message: "\(trap) failed: \(message)", fatal: true)
                }
                return .void
            }
        }
        define("unsafeBitCast") { args, _ in
            // Bit-identity cast: the value passes through (casts are
            // optimistic everywhere in the interpreter).
            args.positional(0) ?? .void
        }
        define("UUID") { _, _ in .native(UUID()) }
        define("URL") { args, _ in
            // Real URL semantics: invalid strings are honestly nil.
            if let s = (args.labeled("string") ?? args.positional(0))?.stringValue {
                return URL(string: s).map { RuntimeValue.native($0) } ?? .nilValue
            }
            if let path = args.labeled("fileURLWithPath")?.stringValue {
                return .native(URL(fileURLWithPath: path))
            }
            // Unknowable string (host-constant markers like
            // UIApplication.openSettingsURLString): the URL is equally
            // unknowable but non-nil on device — the marker flows through.
            if let value = args.labeled("string") ?? args.positional(0), !value.isNil {
                return value
            }
            return .nilValue
        }
        define("Date") { _, _ in .native(Date()) }
    }

    private static func extremum(_ args: CallArguments, op: String) throws -> RuntimeValue {
        let values = args.arguments.map(\.value)
        guard var best = values.first else { throw RuntimeError(message: "min/max need arguments") }
        for value in values.dropFirst() {
            if try Builtins.binary(op, value, best).boolValue == true { best = value }
        }
        return best
    }

    // MARK: - Errors & budget

    func error(_ node: some SyntaxProtocol, _ message: String) -> RuntimeError {
        guard let location = locationConverter?.location(for: node.positionAfterSkippingLeadingTrivia) else {
            return RuntimeError(message: message)
        }
        return RuntimeError(message: message, line: location.line, column: location.column)
    }

    func tick(_ node: some SyntaxProtocol) throws {
        steps += 1
        if steps > stepBudget {
            let located = error(node, "evaluation budget exceeded (possible infinite loop)")
            throw RuntimeError(message: located.message, line: located.line, column: located.column, fatal: true)
        }
    }
}

// MARK: - EvalContext (what gateways can call back into)

extension Interpreter: EvalContext {
    public func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        steps = 0 // fresh entry, e.g. a Button action invoked from the UI
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        return try callWithArguments(closure, args: args, node: nil)
    }

    public func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue] {
        let env = Environment(parent: closure.captured)
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        try bindParameters(of: closure, to: args, into: env, node: nil)
        return try collectBuilderViews(closure.body, in: env)
    }
}
