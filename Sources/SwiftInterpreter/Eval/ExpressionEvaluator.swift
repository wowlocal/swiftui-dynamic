import Foundation
import SwiftSyntax

/// Expression evaluation: the big dispatch over folded `ExprSyntax`.
extension Interpreter {
    func evaluate(_ expr: ExprSyntax, in env: Environment) throws -> RuntimeValue {
        try tick(expr)
        // Native-stack guard for resolution CYCLES that never pass
        // callWithArguments (lazy-global force loops, member-dispatch
        // cycles). A fixed nesting count can't fit both TCA's legitimate
        // depth and small test-thread stacks, so probe the REAL bounds:
        // when under 1MB of headroom remains, stop with a located error.
        evaluationDepth += 1
        defer { evaluationDepth -= 1 }
        if evaluationDepth & 15 == 0 {
            let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
            let size = UInt(pthread_get_stacksize_np(pthread_self()))
            var probe: UInt8 = 0
            let current = withUnsafePointer(to: &probe) { UInt(bitPattern: $0) }
            if current > top - size, current - (top - size) < 1_572_864 {
                if Interpreter.traceStateCells {
                    var counts: [String: Int] = [:]
                    for name in callStackNames { counts[name, default: 0] += 1 }
                    let hot = counts.sorted { $0.value > $1.value }.prefix(8)
                        .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                    FileHandle.standardError.write(Data("   ✖ stack trip; hot frames: \(hot)\n   ✖ head: \(callStackNames.prefix(6).joined(separator: " → "))\n".utf8))
                }
                let located = error(expr, "evaluation nesting exceeded (possible initialization cycle)")
                throw RuntimeError(
                    message: located.message, line: located.line, column: located.column, fatal: true)
            }
        }
        guard evaluationDepth < 20_000 else {
            if Interpreter.traceStateCells {
                var counts: [String: Int] = [:]
                for name in callStackNames { counts[name, default: 0] += 1 }
                let hot = counts.sorted { $0.value > $1.value }.prefix(8)
                    .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                FileHandle.standardError.write(Data("   ✖ nesting trip; hot frames: \(hot)\n   ✖ tail: \(callStackNames.suffix(12).joined(separator: " → "))\n".utf8))
            }
            let located = error(expr, "evaluation nesting exceeded (possible initialization cycle)")
            throw RuntimeError(
                message: located.message, line: located.line, column: located.column, fatal: true)
        }

        // Single jump on the node kind — this dispatch runs once per
        // evaluated node, so a ~25-deep `as()` chain was pure overhead.
        switch expr.kind {
        case .integerLiteralExpr:
            return .native(try integerValue(of: expr.cast(IntegerLiteralExprSyntax.self)))
        case .floatLiteralExpr:
            let lit = expr.cast(FloatLiteralExprSyntax.self)
            guard let d = Double(lit.literal.text.filter { $0 != "_" }) else {
                throw error(lit, "invalid float literal")
            }
            return .native(d)
        case .booleanLiteralExpr:
            return .native(expr.cast(BooleanLiteralExprSyntax.self).literal.text == "true")
        case .nilLiteralExpr:
            return .nilValue
        case .stringLiteralExpr:
            return .native(try stringLiteral(expr.cast(StringLiteralExprSyntax.self), in: env))
        case .arrayExpr:
            let array = expr.cast(ArrayExprSyntax.self)
            return .native(try array.elements.map { try evaluate($0.expression, in: env) })
        case .dictionaryExpr:
            let dict = expr.cast(DictionaryExprSyntax.self)
            let value = DictValue()
            if case .elements(let elements) = dict.content {
                for element in elements {
                    try relocating(element) {
                        try value.update(try evaluate(element.key, in: env), to: try evaluate(element.value, in: env))
                    }
                }
            }
            return .native(value)
        case .declReferenceExpr:
            let ref = expr.cast(DeclReferenceExprSyntax.self)
            return try resolveIdentifier(ref.baseName.text, in: env, node: ref)
        case .memberAccessExpr:
            let member = expr.cast(MemberAccessExprSyntax.self)
            guard let base = member.base else {
                return .implicitMember(member.declName.baseName.text)
            }
            let baseValue = try evaluate(base, in: env)
            return try accessMember(member.declName.baseName.text, on: baseValue, node: member, env: env)
        case .functionCallExpr:
            return try evaluateCall(expr.cast(FunctionCallExprSyntax.self), in: env)
        case .closureExpr:
            return .closure(makeClosure(expr.cast(ClosureExprSyntax.self), in: env))
        case .infixOperatorExpr:
            return try evaluateInfix(expr.cast(InfixOperatorExprSyntax.self), in: env)
        case .prefixOperatorExpr:
            let prefix = expr.cast(PrefixOperatorExprSyntax.self)
            if prefix.operator.text == "..<" || prefix.operator.text == "..." {
                let bound = try evaluate(prefix.expression, in: env)
                return .native(RuntimeRangeValue(
                    upperBound: bound,
                    includesUpperBound: prefix.operator.text == "..."))
            }
            if prefix.operator.text == "/",
               globals.lookup(prefix.operator.text) == nil {
                // The CasePaths case-path operator: `/AppAction.milestone`.
                // Resolve the case reference so extract/embed are REAL for
                // interpreted enums; unknown shapes stay textual markers.
                var enumSymbol: EnumSymbol?
                var caseName: String?
                if let member = prefix.expression.as(MemberAccessExprSyntax.self),
                   let baseExpr = member.base,
                   case .enumType(let symbol)? = try? evaluate(baseExpr, in: env) {
                    enumSymbol = symbol
                    caseName = member.declName.baseName.text
                }
                return .native(CasePathMarker(
                    path: prefix.expression.trimmedDescription,
                    enumSymbol: enumSymbol, caseName: caseName))
            }
            let operand = try evaluate(prefix.expression, in: env)
            do {
                return try relocating(prefix) { try Builtins.prefix(prefix.operator.text, operand) }
            } catch let builtinError as RuntimeError where !builtinError.fatal {
                // User-defined prefix operators (`prefix func √`).
                if case .closure(let closure)? = globals.lookup(prefix.operator.text) {
                    return try callWithArguments(
                        closure,
                        args: CallArguments(arguments: [.init(label: nil, value: operand)]),
                        node: nil)
                }
                throw builtinError
            }
        case .postfixOperatorExpr:
            let postfix = expr.cast(PostfixOperatorExprSyntax.self)
            if postfix.operator.text == "..." {
                let bound = try evaluate(postfix.expression, in: env)
                return .native(RuntimeRangeValue(lowerBound: bound))
            }
            // User-defined postfix operators (`postfix func >*` — 2048's
            // AnyView-erasure operator).
            let operand = try evaluate(postfix.expression, in: env)
            if case .closure(let closure)? = globals.lookup(postfix.operator.text) {
                return try callWithArguments(
                    closure,
                    args: CallArguments(arguments: [.init(label: nil, value: operand)]),
                    node: nil)
            }
            throw error(postfix, "unsupported postfix operator '\(postfix.operator.text)'")
        case .ternaryExpr:
            let ternary = expr.cast(TernaryExprSyntax.self)
            let condition = try expectBool(evaluate(ternary.condition, in: env), node: ternary.condition)
            return try evaluate(condition ? ternary.thenExpression : ternary.elseExpression, in: env)
        case .tupleExpr:
            let tuple = expr.cast(TupleExprSyntax.self)
            if tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil {
                return try evaluate(only.expression, in: env)
            }
            let labels = tuple.elements.map { $0.label?.text }
            let values = try tuple.elements.map { try evaluate($0.expression, in: env) }
            return .native(TupleValue(labels: labels, values: values))
        case .subscriptCallExpr:
            return try evaluateSubscript(expr.cast(SubscriptCallExprSyntax.self), in: env)
        case .forceUnwrapExpr:
            let forceUnwrap = expr.cast(ForceUnwrapExprSyntax.self)
            let value = try evaluate(forceUnwrap.expression, in: env)
            guard !value.isNil else {
                throw error(forceUnwrap, "unexpectedly found nil while force-unwrapping")
            }
            return value
        case .optionalChainingExpr:
            // Member/call/subscript on nil propagates nil (see accessMember/invoke).
            return try evaluate(expr.cast(OptionalChainingExprSyntax.self).expression, in: env)
        case .tryExpr:
            let tryExpr = expr.cast(TryExprSyntax.self)
            if tryExpr.questionOrExclamationMark?.text == "?" {
                do {
                    return try evaluate(tryExpr.expression, in: env)
                } catch is InterpretedThrow {
                    return .nilValue
                } catch let hostError as RuntimeError where !hostError.fatal {
                    return .nilValue
                }
            }
            return try evaluate(tryExpr.expression, in: env) // try / try!
        case .awaitExpr:
            // Synchronous stand-in: async work evaluates inline (documented).
            return try evaluate(expr.cast(AwaitExprSyntax.self).expression, in: env)
        case .keyPathExpr:
            let keyPath = expr.cast(KeyPathExprSyntax.self)
            let components = keyPath.components.map {
                $0.trimmedDescription.hasPrefix(".")
                    ? String($0.trimmedDescription.dropFirst())
                    : $0.trimmedDescription
            }
            return .native(KeyPathStub(components: components))
        case .superExpr:
            if case .instance(let instance)? = env.lookup("self") {
                return .native(SuperReference(instance: instance))
            }
            // STATIC contexts (`static func fetchRequest() { super
            // .fetchRequest() }` on an NSManagedObject subclass): the host
            // superclass's statics absorb — a type marker carries the name.
            if case .type(let symbol)? = env.lookup("self"),
               let superName = symbol.superclassName {
                if case .type(let parent)? = globals.lookup(superName) {
                    return .type(parent)
                }
                return .native(HostTypeMarker(name: superName))
            }
            throw error(expr, "'super' can only be used inside a class body")
        case .inOutExpr:
            let inout_ = expr.cast(InOutExprSyntax.self)
            // `&value` — capture the lvalue so user `inout` parameters can
            // write back; non-closure consumers unwrap to the current value.
            if let target = try? resolveLValue(inout_.expression, in: env) {
                if case .box(let box) = target {
                    return .native(InoutSlot(box: box, target: nil, current: box.value))
                }
                return .native(InoutSlot(box: nil, target: target, current: try target.read(self)))
            }
            return try evaluate(inout_.expression, in: env)
        case .macroExpansionExpr:
            // Registered macros (#expect/#require) execute; the rest stay
            // inert markers (`#selector(...)`, `#Predicate {...}`).
            let macro = expr.cast(MacroExpansionExprSyntax.self)
            if let result = try invokeRegisteredMacro(
                named: macro.macroName.text, arguments: macro.arguments,
                trailingClosure: macro.trailingClosure,
                additionalTrailingClosures: macro.additionalTrailingClosures,
                genericArguments: macro.genericArgumentClause?.arguments
                    .map { $0.argument.trimmedDescription }.joined(separator: ", "),
                node: macro, in: env) {
                return result
            }
            return .native(HostTypeMarker(name: "#\(macro.macroName.text)"))
        case .isExpr:
            // `value is Type` — checkable shapes really check (primitives,
            // interpreted symbols, host type names); unknowables read FALSE
            // (fresh state: nothing persisted IS anything yet).
            let isExpr = expr.cast(IsExprSyntax.self)
            let subject = try evaluate(isExpr.expression, in: env)
            return .native(valueIsType(subject, isExpr.type.trimmedDescription))
        case .asExpr:
            let asExpr = expr.cast(AsExprSyntax.self)
            // Dynamic casts: give the target type a chance to resolve markers,
            // bridge numerics, and otherwise pass the value through
            // (optimistic `as?` — documented divergence).
            let value = try evaluate(asExpr.expression, in: env)
            if asExpr.questionOrExclamationMark?.text == "?", value.isNil {
                return .nilValue
            }
            var typeName = asExpr.type.trimmedDescription
            if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }
            // A DEFINITE mismatch is nil when both sides are declared in
            // this merge (`action as? AsyncAction` over a plain Action —
            // the SwiftUIFlux dispatch genre); host values and unknown
            // types keep the optimistic pass-through divergence.
            if asExpr.questionOrExclamationMark?.text == "?" {
                let checkable: Bool
                switch value {
                case .instance, .enumCase: checkable = true
                default: checkable = false
                }
                let declaredTarget = typeValue(named: typeName) != nil
                    || protocolInheritance[typeName] != nil
                if checkable, declaredTarget, !valueIsType(value, typeName) {
                    return .nilValue
                }
            }
            switch typeName {
            case "Double", "CGFloat", "TimeInterval":
                if let d = value.doubleValue { return .native(d) }
            case "Int":
                if let d = value.doubleValue { return .native(Int(d)) }
            default:
                break
            }
            return try resolveAnnotated(value, typeName: typeName)
        case .ifExpr:
            let ifExpr = expr.cast(IfExprSyntax.self)
            if case .normal(let value) = try executeIf(ifExpr, in: env) { return value }
            throw error(ifExpr, "control flow can't escape an if-expression")
        case .switchExpr:
            let switchExpr = expr.cast(SwitchExprSyntax.self)
            if case .normal(let value) = try executeSwitch(switchExpr, in: env) { return value }
            throw error(switchExpr, "control flow can't escape a switch-expression")
        case .postfixIfConfigExpr:
            // `view \n #if os(iOS) \n .modifier() \n #endif` — apply the
            // active clause's postfix chain to the base (inactive: base).
            let postfixIf = expr.cast(PostfixIfConfigExprSyntax.self)
            let baseValue = try postfixIf.base.map { try evaluate($0, in: env) } ?? .void
            guard let clause = activeIfConfigClause(postfixIf.config),
                  case .postfixExpression(let postfix)? = clause.elements else {
                return baseValue
            }
            let child = Environment(parent: env)
            child.define("__postfixBase", baseValue)
            return try evaluate(graftPostfixBase(postfix, name: "__postfixBase"), in: child)
        case .genericSpecializationExpr:
            // `FetchDescriptor<DBModel.Country>()` — HOST constructors get
            // the specialization as a hidden argument, so type-carrying
            // boxes (fetch descriptors) know their model type.
            if let spec = expr.as(GenericSpecializationExprSyntax.self) {
                let resolved = try evaluate(spec.expression, in: env)
                if case .hostFunction(let ctor) = resolved {
                    let genericText = spec.genericArgumentClause.arguments
                        .map { $0.argument.trimmedDescription }
                        .joined(separator: ", ")
                    return .hostFunction(HostFunction(name: ctor.name) { args, ctx in
                        var enriched = args.arguments
                        enriched.append(.init(label: "__genericArguments", value: .native(genericText)))
                        return try ctor.invoke(CallArguments(arguments: enriched), ctx)
                    })
                }
                return resolved
            }
            // Type arguments are annotations we don't check —
            // `Binding<Int?>(get:set:)` evaluates as `Binding(get:set:)`.
            return try evaluate(expr.cast(GenericSpecializationExprSyntax.self).expression, in: env)
        case .discardAssignmentExpr:
            return .void // `_` in expression position — a write-only slot
        case .sequenceExpr:
            throw error(expr, "internal error: unfolded operator sequence")
        default:
            throw error(expr, "unsupported expression (\(expr.kind))")
        }
    }

    /// Grafts a name reference onto the missing root base of a postfix
    /// chain from `#if`-postfix clauses (`.padding().background(...)`).
    private func graftPostfixBase(_ expr: ExprSyntax, name: String) -> ExprSyntax {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            if let base = member.base {
                return ExprSyntax(member.with(\.base, graftPostfixBase(base, name: name)))
            }
            return ExprSyntax(member.with(
                \.base, ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(name)))))
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return ExprSyntax(call.with(
                \.calledExpression, graftPostfixBase(call.calledExpression, name: name)))
        }
        return expr
    }

    // MARK: - Identifiers & members

    /// Lazy globals evaluate their initializer on first read (memoized).
    func force(_ box: Box) throws -> RuntimeValue {
        if case .host(let any) = box.value, let computed = any as? ComputedGlobal {
            // Global computed var: evaluate fresh on every read.
            let result = try executeBlock(computed.accessor, in: Environment(parent: globals))
            switch result {
            case .normal(let value), .returnValue(let value):
                return try resolveAnnotated(value, annotation: computed.annotation)
            default:
                return .void
            }
        }
        guard case .host(let any) = box.value, let lazy = any as? LazyGlobal else {
            return box.value
        }
        var value: RuntimeValue = lazy.annotation?.trimmedDescription.hasSuffix("?") == true
            ? .nilValue : .void
        if let initializer = lazy.initializer {
            value = try resolveAnnotated(try evaluate(initializer, in: globals), annotation: lazy.annotation)
        }
        box.value = value
        return value
    }

    /// Diagnostics: INTERP_TRACE_CALLS="a,b,c" prints each entry into a
    /// matching declared function — localizing silent absorbs in deep chains.
    static let tracedCallNames: Set<String>? = ProcessInfo.processInfo
        .environment["INTERP_TRACE_CALLS"].map { Set($0.split(separator: ",").map(String.init)) }

    /// `$selectedTab` / `self.$selectedTab` / `home.$selectedTab` — the
    /// projected value of a wrapper property on an INSTANCE: @Published's
    /// inert publisher, model projections for object wrappers, and
    /// BindingStub for @State/@Binding storage.
    func instanceProjection(
        _ propertyName: String, on instance: Instance, node: some SyntaxProtocol
    ) throws -> RuntimeValue {
        // `$searchText` on a @Published property (inside the model) is
        // the Combine publisher projection — an inert pipeline.
        if let property = instance.symbol.storedProperty(named: propertyName),
           property.wrapper == .published {
            // Replay/live registries deliver the CURRENT value synchronously
            // (the doctrine fork); absorbed mode stays inert.
            if let current = instance.box(for: propertyName)?.value,
               let publisher = registry?.publishedProjection(current: current) {
                return publisher
            }
            return .native(PublishedProjection())
        }
        // `$store` on a model property projects the model so `$store.field`
        // can become a binding to the model's own box.
        if let property = instance.symbol.storedProperty(named: propertyName),
           property.wrapper == .stateObject || property.wrapper == .observedObject
            || property.wrapper == .environmentObject {
            let boxValue = instance.box(for: propertyName)?.value
            guard case .instance(let model)? = boxValue else {
                // External-package models synthesize as unknowables —
                // their projection is equally unknowable (absorbs).
                if case .host(let any)? = boxValue,
                   any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                    return boxValue ?? .nilValue
                }
                if case .implicitMember? = boxValue { return boxValue ?? .nilValue }
                if case .hostFunction? = boxValue { return boxValue ?? .nilValue }
                throw error(node, "'$\(propertyName)' has no model instance assigned")
            }
            return .native(ModelProjection(model: model))
        }
        guard let box = instance.projectedBox(for: propertyName) else {
            throw error(node, "'$\(propertyName)' requires an @State or @Binding property named '\(propertyName)'")
        }
        return .native(BindingStub(box: box))
    }

    func resolveIdentifier(_ name: String, in env: Environment, node: some SyntaxProtocol) throws -> RuntimeValue {
        if let probe = ProcessInfo.processInfo.environment["INTERP_TRACE_IDENT"], probe == name {
            let result = Result { try resolveIdentifierCore(name, in: env, node: node) }
            let location = error(node, "").line
            let owners = lexicalOwnerFrames.map {
                ($0 as? StructSymbol)?.name ?? ($0 as? EnumSymbol)?.name ?? "?"
            }
            switch result {
            case .success(let value):
                var detail = value.stringified.prefix(60).description
                if case .enumType(let symbol) = value {
                    detail += "(cases: \(symbol.cases.map(\.name).prefix(4).joined(separator: ",")))"
                }
                Swift.print("   ⌖ \(name)@\(location) → \(detail) owners=\(owners)")
                return value
            case .failure(let failure):
                Swift.print("   ⌖ \(name)@\(location) → THREW \(failure) owners=\(owners)")
                throw failure
            }
        }
        return try resolveIdentifierCore(name, in: env, node: node)
    }

    private func resolveIdentifierCore(_ name: String, in env: Environment, node: some SyntaxProtocol) throws -> RuntimeValue {
        // Real Swift scoping: locals first, implicit-self members second,
        // globals LAST (a method named like a global type wins in its body).
        if let box = env.box(for: name, before: globals) { return try force(box) }
        // `$count` — projected value of an @State or @Binding property.
        // (`$0`-style closure shorthands were already bound in the environment.)
        if name.hasPrefix("$"), name.count > 1, !name.dropFirst().allSatisfy(\.isNumber) {
            let propertyName = String(name.dropFirst())
            // `@Bindable var x = model` — a LOCAL holding a model instance
            // projects member bindings (`$x.activeTab`); a local binding
            // projects itself.
            if let localBox = env.box(for: propertyName) {
                let local = try force(localBox)
                if case .instance(let model) = local {
                    return .native(ModelProjection(model: model))
                }
                if case .host(let any) = local, any is BindingStub {
                    return local
                }
            }
            guard case .instance(let instance)? = env.lookup("self") else {
                throw error(node, "'\(name)' can only be used inside a View body")
            }
            return try instanceProjection(propertyName, on: instance, node: node)
        }
        if let selfValue = env.lookup("self"),
           let value = try selfMember(name, on: selfValue) {
            return value
        }
        if let box = globals.box(for: name) { return try force(box) }
        // Operator-function references (`reduce(0, +)`, `sorted(by: >)`) —
        // real Swift passes the global operator function; ours applies the
        // builtin table. User-declared operator functions won above (globals).
        if name.count <= 3, name.allSatisfy({ "+-*/%<>=!&|^~".contains($0) }) {
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let lhs = args.positional(0), let rhs = args.positional(1) else {
                    throw EvalMessage(text: "operator '\(name)' needs two arguments")
                }
                return try Builtins.binary(name, lhs, rhs)
            })
        }
        if name == "Self", let selfValue = env.lookup("self") {
            switch selfValue {
            case .instance(let instance):
                return globals.lookup(instance.symbol.name) ?? .type(instance.symbol)
            case .type, .enumType:
                return selfValue
            default:
                break
            }
        }
        if let ctor = registry?.constructor(named: aliasHeads[name] ?? name) {
            return .hostFunction(ctor)
        }
        // Unknown type-looking names are assumed host types used for static
        // access (Color.red, UIScreen.main). Calling them errors clearly.
        if let first = name.first, first.isUppercase {
            return .native(HostTypeMarker(name: name))
        }
        // LAST resort — unqualified MODIFIER calls inside View-extension
        // bodies: `func withSheet(…) -> some View { sheet(item:…) { … } }`.
        // Everything else resolved above (members, globals, constructors),
        // so this only rescues would-be-unresolved lowercase names when
        // implicit self is a view (native or interpreted instance).
        // C-interop names never rescue as modifiers: inside host-type
        // extension bodies (self = host object) a bare `uname(&info)` must
        // reach the C absorber below, not the registry's modifier table.
        if let selfValue = env.lookup("self"),
           !Self.looksLikeCImport(name),
           registry?.cFunction(named: name) == nil,
           let modifier = registry?.modifier(named: name),
           let target = modifierTarget(for: selfValue) {
            return .hostFunction(HostFunction(name: name) { args, ctx in
                try modifier.apply(target, args, ctx)
            })
        }
        // Unresolved snake_case identifiers are C imports (sqlite3_open,
        // ndb_builder — the merge holds all the app's OWN Swift): inert
        // absorbing functions, values chain per the fresh-state doctrine.
        if Self.looksLikeCImport(name) || assumesCompiledImports {
            if let real = registry?.cFunction(named: name) { return .hostFunction(real) }
            // SCREAMING_SNAKE identifiers are C CONSTANTS (EXIT_SUCCESS,
            // _SYS_NAMELEN): numeric-absorbing markers, not host types.
            if name.contains("_"), name.dropFirst(name.hasPrefix("_") ? 1 : 0)
                .allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                return .implicitMember(name)
            }
            return .hostFunction(HostFunction(name: name) { [weak self] _, _ in
                self?.registry?.absorbedCValue(named: name)
                    ?? .native(ChainedImplicitCall(
                        base: .implicitMember(name), member: "call", arguments: CallArguments()))
            })
        }
        throw error(node, "unresolved identifier '\(name)'")
    }

    /// Implicit-self member resolution (works for struct instances, enum
    /// values, and native selves inside host-extension method bodies).
    private func selfMember(_ name: String, on selfValue: RuntimeValue) throws -> RuntimeValue? {
        switch selfValue {
        case .instance(let instance):
            return try instanceMember(name, on: instance)
        case .enumCase(let value):
            return try enumCaseMember(name, on: value)
        case .type(let symbol):
            // Static context: bare sibling-static references inside a
            // `static var`/`static func` body.
            return try staticMember(name, of: symbol)
        case .enumType(let symbol):
            return try staticMember(name, of: symbol)
        case .int, .double, .bool, .host:
            // Bare `count`/`firstIndex(...)` inside a host-type extension body
            // is implicit self on the native value. Inline scalars box on
            // demand — member dispatch wants the uniform Any path.
            let any = selfValue.hostPayload!
            if let stub = any as? BindingStub {
                // `wrappedValue.setIsLoading(…)` inside `extension Binding`
                // — the binding's own properties resolve bare.
                if name == "wrappedValue" { return stub.box.value }
                if name == "projectedValue" { return selfValue }
            }
            if let value = try nativeMember(name, on: any) { return value }
            if let value = registry?.hostMember(name, on: any) { return value }
            return try hostExtensionMember(name, candidates: hostCandidates(for: any), selfValue: selfValue)
        default:
            return nil
        }
    }

    /// Property → method → computed property → own nested types, or nil
    /// if the name is unknown.
    func instanceMember(_ rawName: String, on instance: Instance) throws -> RuntimeValue? {
        // `self.$selectedTab` / `home.$path` — member-form projections
        // resolve exactly like bare `$name` (the TV-home genre passes
        // `self.$selectedTab` into a child's @Binding).
        if rawName.hasPrefix("$"), rawName.count > 1,
           !rawName.dropFirst().allSatisfy(\.isNumber) {
            return try instanceProjection(
                String(rawName.dropFirst()), on: instance,
                node: Syntax(DeclReferenceExprSyntax(baseName: .identifier(rawName))))
        }
        let name = instance.symbol.canonicalPropertyName(rawName)
        if name == "objectWillChange", instance.symbol.isClass {
            let signal = instance.changeSignal
            return .native(ObjectWillChangePublisher(fire: { signal.fire() }))
        }
        if let box = instance.box(for: name),
           case .host(let any) = box.value, let seed = any as? LazyMemberSeed {
            // Force the lazy member now, with self bound.
            let value = try resolveAnnotated(
                try evaluate(seed.initializer, in: selfEnvironment(.instance(instance))),
                annotation: seed.annotation)
            box.value = value
            return value
        }
        // A type's OWN nested types shadow same-named globals inside its
        // body (each IceCubes package declares its own `enum Constants`) —
        // scoped LEXICALLY to the running method's declaring type, so
        // protocol-extension bodies never see the runtime self's nesteds.
        if let nested = lexicalNestedType(name, runtime: instance.symbol) { return nested }
        if let box = instance.box(for: name) { return box.value }
        // Dynamic dispatch: the instance's OWN members win (overrides beat
        // the inherited definition), THEN interpreted-superclass members
        // dispatch with self unchanged, walking the chain.
        if let overloads = instance.symbol.methods[name], let first = overloads.first {
            // A PROPERTY/METHOD name collision (`var filteredReadings` +
            // `func filteredReadings(for:)`): a bare reference is the
            // property when every method overload requires arguments.
            if instance.symbol.computedProperties[name] != nil,
               overloads.allSatisfy({ method in
                   method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
               }) {
                return try evaluateComputed(
                    instance.symbol.computedProperties[name]!,
                    selfValue: .instance(instance), name: name)
            }
            // Within an OVERLOAD SET the running declaration never re-enters
            // itself: `send(_:) -> StoreTask` delegates to its identically-
            // shaped sibling (return-type disambiguation). A set exhausted
            // by recursion absorbs — but a UNIQUE decl recursing (fib) is
            // legitimate and stays.
            var method = first
            if overloads.count > 1 {
                guard let candidate = overloads.first(where: { !activeFunctionBodies.contains($0.id) }) else {
                    return .native(ChainedImplicitCall(
                        base: .instance(instance), member: name, arguments: CallArguments()))
                }
                method = candidate
            }
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.instance(instance))))
        }
        if let computed = instance.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
        }
        var parentName = instance.symbol.superclassName
        while let superName = parentName {
            guard case .type(let parent)? = globals.lookup(superName) else { break }
            if let overloads = parent.methods[name], let firstMethod = overloads.first {
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstMethod)
                    : firstMethod
                if let body = method.body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.instance(instance))))
                }
            }
            if let computed = parent.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
            parentName = parent.superclassName
        }
        if instance.symbol.conformsToView,
           let value = try hostExtensionMember(name, candidates: ["View"], selfValue: .instance(instance)) {
            return value
        }
        // Protocol-extension defaults: `extension GameLogic { func start() … }`
        // serves conformers that don't define the member themselves —
        // through protocol REFINEMENT too (CountriesWebRepository:
        // WebRepository reaches WebRepository's `call(endpoint:)`).
        for conformance in transitiveConformances(of: instance.symbol) {
            guard let proto = hostExtensionSymbols[conformance] else { continue }
            if let overloads = proto.methods[name], let firstMethod = overloads.first {
                // PROPERTY/METHOD collision in the same extension (AnyStatus
                // declares `var isHidden` AND `func isHidden(in:)`): a bare
                // reference is the property when every method overload
                // requires arguments — the instanceMember rule.
                if let computed = proto.computedProperties[name],
                   overloads.allSatisfy({ method in
                       method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
                   }) {
                    return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
                }
                // Overload sets never re-enter the running declaration
                // (IconDrawable's image(ofSize:color:) → edgeInsets form,
                // served to conformers through the protocol-defaults walk).
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstMethod)
                    : firstMethod
                if let body = method.body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.instance(instance))))
                }
            }
            if let computed = proto.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
        }
        // @ModelActor's generated `modelContext` reads the bound
        // container's shared context.
        if name == "modelContext",
           instance.symbol.attributeNames.contains("ModelActor"),
           let container = instance.box(for: "modelContainer")?.value,
           case .host(let containerAny) = container,
           let member = registry?.hostMember("mainContext", on: containerAny) {
            return member
        }
        // Bare sibling STATICS are visible from any member context
        // (`assert(blurRadius > 0)` where the parameter default is
        // `defaultBlurRadius`, a static let on the type) — resolved in the
        // DECLARING type's scope: a protocol-extension body sees the
        // extension's own statics/nesteds, never the runtime conformer's
        // (clean-architecture's test double nests a shadowing APIError).
        let staticScope = (lexicalOwnerFrames.last as? StructSymbol) ?? instance.symbol
        if let value = try staticMember(name, of: staticScope) {
            return value
        }
        return nil
    }

    /// Interpreted extension-of-host-type members (`extension View { … }`).
    func hostExtensionMember(_ name: String, candidates: [String], selfValue: RuntimeValue) throws -> RuntimeValue? {
        for typeName in candidates {
            guard let symbol = hostExtensionSymbols[typeName] else { continue }
            if let overloads = symbol.methods[name], let firstOverload = overloads.first {
                // Bare reference on a property/method collision: the
                // property wins when every overload requires arguments —
                // UNLESS that property is already evaluating (its body
                // calling the same-named METHOD must reach the method:
                // nextcloud's `var resolvedWindow` calls
                // `resolvedWindow(in:)`).
                let collisionKey = "\(typeName).\(name)"
                if let computed = symbol.computedProperties[name],
                   !activeCollisionProperties.contains(collisionKey),
                   overloads.allSatisfy({ method in
                       method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
                   }) {
                    activeCollisionProperties.insert(collisionKey)
                    defer { activeCollisionProperties.remove(collisionKey) }
                    return try evaluateComputed(computed, selfValue: selfValue, name: name)
                }
                // Overload sets never re-enter the running declaration
                // (IconDrawable's image(ofSize:color:) delegating to the
                // edgeInsets form).
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstOverload)
                    : firstOverload
                guard let body = method.body else { return nil }
                let frame = ExtensionFrame(typeName: typeName, member: name)
                // A same-named self-call INSIDE this method's own body is
                // the other overload (UTM: onReceive(Notification.Name…)
                // delegating to SwiftUI's onReceive(publisher…)) — prefer
                // the registry gateway when one exists; recurse only when
                // there is no alternative (fib-style helpers).
                if activeExtensionFrames.contains(frame),
                   let registry, registry.isViewValue(selfValue),
                   registry.modifier(named: name) != nil {
                    continue
                }
                let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(selfValue))
                closure.extensionFrame = frame
                closure.functionDeclID = method.id
                return .closure(closure)
            }
            if let computed = symbol.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: selfValue, name: name)
            }
        }
        return nil
    }

    func hostCandidates(for any: Any) -> [String] {
        var names: [String] = []
        if let registry, registry.isViewValue(.native(any)) { names.append("View") }
        if let typeName = registry?.hostTypeName(of: any) { names.append(typeName) }
        if let protocols = registry?.hostProtocolCandidates(of: any), !protocols.isEmpty {
            names.append(contentsOf: protocols)
        }
        if any is String { names.append("String") }
        if any is Int { names.append("Int") }
        if any is Double { names.append("Double"); names.append("CGFloat") }
        if any is Bool { names.append("Bool") }
        if any is Date { names.append("Date") }
        if any is BindingStub { names.append("Binding") }
        if any is DictValue { names.append("Dictionary") }
        if any is Data { names.append("Data") }
        if any is URL { names.append("URL") }
        if any is UUID { names.append("UUID") }
        if let range = any as? RuntimeRangeValue {
            switch (range.lowerBound, range.upperBound, range.includesUpperBound) {
            case (.some, .some, false): names.append("Range")
            case (.some, .some, true): names.append("ClosedRange")
            case (.some, nil, _): names.append("PartialRangeFrom")
            case (nil, .some, false): names.append("PartialRangeUpTo")
            case (nil, .some, true): names.append("PartialRangeThrough")
            default: break
            }
            names.append("RangeExpression")
        }
        if any is [RuntimeValue] {
            // `extension Array` and sugar-typed `extension [Item]` both apply.
            names.append("Array")
            names.append(contentsOf: hostExtensionSymbols.keys.filter { $0.hasPrefix("[") })
        }
        // Protocol umbrellas: `extension Collection { var isNotEmpty }`
        // applies to every conforming native (twostraws idiom).
        let integerRangeCollection = (any as? RuntimeRangeValue).map {
            $0.lowerBound?.intValue != nil && $0.upperBound?.intValue != nil
        } ?? false
        if any is [RuntimeValue] || any is String || any is DictValue || integerRangeCollection {
            names.append("Collection")
            names.append("Sequence")
        }
        if any is [RuntimeValue] || integerRangeCollection {
            names.append("RandomAccessCollection")
        }
        if any is [RuntimeValue] {
            names.append("MutableCollection")
            names.append("BidirectionalCollection")
        }
        if any is String { names.append("StringProtocol") }
        if any is Int { names.append("BinaryInteger"); names.append("Numeric") }
        if any is Double { names.append("FloatingPoint"); names.append("BinaryFloatingPoint") }
        return names
    }

    private func enumCaseMember(_ name: String, on value: EnumCaseValue) throws -> RuntimeValue? {
        if name == "hashValue" {
            // Synthesized Hashable: equal cases hash equal (name +
            // stringified payloads — deterministic under the tools'
            // SWIFT_DETERMINISTIC_HASHING re-exec).
            var hasher = Hasher()
            hasher.combine(value.symbol.name)
            hasher.combine(value.name)
            for payload in value.associated { hasher.combine(payload.stringified) }
            return .native(hasher.finalize())
        }
        if name == "rawValue" { return value.rawValue }
        if let overloads = value.symbol.methods[name], let first = overloads.first {
            // Overload sets never re-enter the running declaration
            // (IconDrawable's image(ofSize:color:) → edgeInsets form,
            // merged into the enum via its conformance extension).
            let method = overloads.count > 1
                ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? first)
                : first
            guard let body = method.body else { return nil }
            let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumCase(value)))
            closure.functionDeclID = method.id
            return .closure(closure)
        }
        if let computed = value.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .enumCase(value), name: name)
        }
        // Protocol-extension members (`extension RawRepresentable where
        // Self: NotificationName { var name }`): the enum's conformances
        // (plus RawRepresentable itself for raw-valued enums) dispatch.
        var candidates = value.symbol.conformances + ["RawRepresentable"]
        candidates.removeAll { ["String", "Int", "Double", "Codable", "Hashable", "Equatable"].contains($0) }
        if let member = try hostExtensionMember(name, candidates: candidates, selfValue: .enumCase(value)) {
            return member
        }
        if name == "localizedDescription" {
            // Every Error carries this on device. Foundation consults
            // LocalizedError's errorDescription first, then falls back to
            // the NSError boilerplate.
            if let described = try enumCaseMember("errorDescription", on: value),
               let text = described.stringValue {
                return .native(text)
            }
            return .native("The operation couldn\u{2019}t be completed. (\(value.symbol.name) error.)")
        }
        return nil
    }

    /// Runs the best-matching user subscript getter (picked by arity).
    func callUserSubscriptGetter(on instance: Instance, with args: CallArguments) throws -> RuntimeValue {
        try runUserSubscriptGetter(instance.symbol, selfValue: .instance(instance), args: args)
    }

    /// Runs the user subscript setter with `newValue` and the index bound.
    func callUserSubscriptSetter(on instance: Instance, with args: CallArguments, newValue: RuntimeValue) throws {
        try runUserSubscriptSetter(instance.symbol, selfValue: .instance(instance), args: args, newValue: newValue)
    }

    /// The symbol whose user subscripts serve `base`: an interpreted
    /// instance's own, or — for host values — the EXTENSION symbol under
    /// the value's host type name (clean-architecture's
    /// `extension Store { subscript(keyPath:) }` on CurrentValueSubject).
    func userSubscriptOwner(for base: RuntimeValue) -> (StructSymbol, RuntimeValue)? {
        if case .instance(let instance) = base, !instance.symbol.subscripts.isEmpty {
            return (instance.symbol, base)
        }
        if case .host(let any) = base,
           let typeName = registry?.hostTypeName(of: any),
           let extensionSymbol = hostExtensionSymbols[typeName],
           !extensionSymbol.subscripts.isEmpty {
            return (extensionSymbol, base)
        }
        return nil
    }

    func runUserSubscriptGetter(
        _ symbol: StructSymbol, selfValue: RuntimeValue, args: CallArguments
    ) throws -> RuntimeValue {
        guard let member = symbol.subscripts.first(where: { $0.parameters.count == args.arguments.count })
            ?? symbol.subscripts.first else {
            throw RuntimeError(message: "'\(symbol.name)' has no subscript")
        }
        let env = selfEnvironment(selfValue)
        let closure = ClosureValue(parameters: member.parameters, body: member.getter, captured: env)
        return try callWithArguments(closure, args: args, node: nil)
    }

    func runUserSubscriptSetter(
        _ symbol: StructSymbol, selfValue: RuntimeValue, args: CallArguments, newValue: RuntimeValue
    ) throws {
        guard let member = symbol.subscripts.first(where: { $0.parameters.count == args.arguments.count })
            ?? symbol.subscripts.first else {
            throw RuntimeError(message: "'\(symbol.name)' has no subscript")
        }
        guard let setter = member.setter else {
            throw RuntimeError(message: "subscript on '\(symbol.name)' is get-only")
        }
        let env = selfEnvironment(selfValue)
        for (parameter, argument) in zip(member.parameters, args.arguments) {
            env.define(parameter.name, try resolveAnnotated(argument.value, parameter: parameter))
        }
        env.define(setter.parameterName, newValue)
        _ = try executeBlock(setter.body, in: env)
    }

    func evaluateComputed(_ computed: ComputedProperty, selfValue: RuntimeValue, name: String) throws -> RuntimeValue {
        callDepth += 1
        defer { callDepth -= 1 }
        guard callDepth < callDepthLimit else {
            throw RuntimeError(message: "call depth exceeded evaluating '\(name)' (possible infinite recursion)", fatal: true)
        }
        let env = selfEnvironment(selfValue)
        if computed.isBuilder {
            let views = try collectBuilderViews(computed.accessor, in: env)
            return try groupViews(views)
        }
        let result = try executeBlock(computed.accessor, in: env)
        switch result {
        case .normal(let value), .returnValue(let value): return value
        default: throw RuntimeError(message: "control flow escaped computed property '\(name)'")
        }
    }

    func groupViews(_ views: [RuntimeValue]) throws -> RuntimeValue {
        if views.count == 1 { return views[0] }
        guard let registry else {
            throw RuntimeError(message: "no host registry configured")
        }
        return try registry.makeGroup(views)
    }

    func accessMember(_ name: String, on baseValue: RuntimeValue, node: some SyntaxProtocol, env: Environment) throws -> RuntimeValue {
        if name == "self" {
            return baseValue // `SizeKey.self`, `x.self` — the value itself
        }
        switch baseValue {
        case .nilValue:
            // Ecosystem Optional truths (swift-extras): nil knows it's nil.
            if name == "isNil" { return .native(true) }
            if name == "isSome" || name == "isNotNil" { return .native(false) }
            // User extensions on Optional (`var isNil: Bool { self == nil }`)
            // dispatch with self = nil before nil-propagation.
            if let optionalExtension = hostExtensionSymbols["Optional"] {
                if let computed = optionalExtension.computedProperties[name] {
                    return try evaluateComputed(computed, selfValue: .nilValue, name: name)
                }
                if let overloads = optionalExtension.methods[name], let method = overloads.first,
                   let body = method.body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.nilValue)))
                }
            }
            // Optional chaining: member access on nil is nil.
            return .nilValue

        case .instance(let instance):
            // `self.init(…)` — delegating initializers run another init on
            // the SAME instance (convenience inits). A failable delegate
            // that returns nil fails the WHOLE init (sentinel unwinds to
            // runInitializer, which reports nil).
            if name == "init", !instance.symbol.initializers.isEmpty {
                return .hostFunction(HostFunction(name: "init") { [weak self] args, _ in
                    guard let self else { throw RuntimeError(message: "interpreter gone") }
                    // The RUNNING init never re-enters itself: extension
                    // convenience inits delegate to the memberwise form.
                    let available = instance.symbol.initializers.filter {
                        !self.activeInitializers.contains($0.id)
                    }
                    if self.chooseInitializerStrict(from: available, for: args) == nil,
                       available.count < instance.symbol.initializers.count {
                        let propertyNames = Set(self.inheritedStoredProperties(of: instance.symbol).map(\.name))
                        let labels = args.arguments.compactMap(\.label)
                        if !labels.isEmpty, labels.allSatisfy({ propertyNames.contains($0) }) {
                            for argument in args.arguments {
                                guard let label = argument.label else { continue }
                                if let box = instance.box(for: label) {
                                    box.value = argument.value
                                } else {
                                    instance.properties[label] = Box(argument.value)
                                }
                            }
                            return .void
                        }
                    }
                    guard let chosen = self.chooseInitializerStrict(
                        from: available, for: args) else {
                        // No interpreted candidate: `self.init(window:)`
                        // delegates to a HOST superclass's designated init —
                        // labeled args bind as properties (iter-93 rule).
                        // A blind fallback here self-delegates forever.
                        for argument in args.arguments {
                            guard let label = argument.label else { continue }
                            instance.properties[label] = Box(argument.value)
                        }
                        return .void
                    }
                    let outcome = try self.runInitializer(
                        chosen, on: instance, args: args, node: nil)
                    if outcome.isNil {
                        throw RuntimeError(message: Interpreter.initFailedSentinel)
                    }
                    return .void
                })
            }
            if let value = try instanceMember(name, on: instance) {
                // A nil STORED closure sharing a modifier's name
                // (`.onSubmit { }` on a Representable declaring
                // `var onSubmit: (() -> Void)?`): real overload resolution
                // can't call nil — the registry modifier applies.
                if value.isNil, instance.symbol.rendersLikeView,
                   let property = instance.symbol.storedProperty(named: name),
                   property.typeAnnotation?.trimmedDescription.contains("->") == true,
                   let registry, let modifier = registry.modifier(named: name) {
                    let wrapped = registry.makeRenderable(instance: instance, interpreter: self)
                    return .hostFunction(HostFunction(name: name) { args, ctx in
                        try modifier.apply(wrapped, args, ctx)
                    })
                }
                return value
            }
            // A modifier applied to an interpreted View (or Shape — the
            // registry wraps those shape-typed, so .fill/.stroke/.trim see a
            // shape): wrap it renderable first.
            if instance.symbol.rendersLikeView
                || instance.symbol.conformsToShape || instance.symbol.conformsToLayout,
               let registry,
               let modifier = registry.modifier(named: name) {
                let wrapped = registry.makeRenderable(instance: instance, interpreter: self)
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(wrapped, args, ctx)
                })
            }
            if assumesCompiledImports {
                // Compiled sources: an unknown member that survived every
                // dispatch (own, inherited, protocol extensions) is an
                // UNMERGED extension — absorbs.
                return .native(ChainedImplicitCall(
                    base: baseValue, member: name, arguments: CallArguments()))
            }
            throw error(node, "'\(instance.symbol.name)' has no member '\(name)'")

        case .enumCase(let value):
            if let member = try enumCaseMember(name, on: value) { return member }
            throw error(node, "'\(value.symbol.name).\(value.name)' has no member '\(name)'")

        case .enumType(let symbol):
            if let caseInfo = symbol.caseInfo(named: name) {
                if caseInfo.hasAssociatedValues {
                    return .hostFunction(HostFunction(name: name) { args, _ in
                        .enumCase(EnumCaseValue(symbol: symbol, name: name, associated: args.arguments.map(\.value)))
                    })
                }
                return .enumCase(EnumCaseValue(symbol: symbol, name: name))
            }
            if name == "allCases",
               symbol.staticComputedProperties["allCases"] == nil,
               symbol.staticMethods["allCases"]?.contains(where: { method in
                   !method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
               }) != true {
                // SYNTHESIZED CaseIterable for BARE references — an argful
                // `static func allCases(for:)` overload dispatches at CALL
                // sites (below), while its body's bare `allCases` still
                // reads the synthesized array (the property/method
                // collision rule, static flavor).
                let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                    RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
                }
                return .native(all)
            }
            if let value = try staticMember(name, of: symbol) {
                return value
            }
            // An interpreted enum SHADOWING a host type (home-assistant's
            // design-token `Color` vs SwiftUI.Color): statics the enum
            // doesn't declare cross the module boundary to the host.
            if let member = registry?.hostMember(name, on: HostTypeMarker(name: symbol.name)) {
                return member
            }
            if assumesCompiledImports, name.first?.isUppercase == true,
               symbol.attributeNames.contains(where: { $0.first?.isUppercase == true }) {
                // MACRO-ATTRIBUTED enums (@Reducer) generate nested types
                // the merge can't see (State/Action): an absorbing type
                // marker. Plain enums keep the fast throw — launch-hook
                // tolerance depends on it.
                return .native(HostTypeMarker(name: "\(symbol.name).\(name)"))
            }
            throw error(node, "'\(symbol.name)' has no case or static member '\(name)'")

        case .type(let symbol):
            if name == "init" {
                return baseValue // `Self.init(...)` ≡ `Self(...)`
            }
            if let nested = symbol.nestedTypes[name] {
                return nested
            }
            if let value = try staticMember(name, of: symbol) {
                return value
            }
            // Vendored types sharing a host type's name (Lottie's `struct
            // Color`): the miss falls through to the bridge's statics
            // (Color.black) or the gateway-boundary implicit member.
            if registry?.constructor(named: symbol.name) != nil {
                if let value = registry?.hostMember(name, on: HostTypeMarker(name: symbol.name)) {
                    return value
                }
                return .implicitMember(name)
            }
            throw error(node, "'\(symbol.name)' has no static member '\(name)'")

        case .implicitMember(let baseName):
            // View modifiers on color-shaped bases (`Color.black.ignoresSafeArea()`)
            // route to the modifier table; `opacity`/`gradient` stay opaque
            // chains because they're style transforms, not view modifiers here.
            if name != "opacity", name != "gradient",
               let registry, registry.isViewValue(baseValue),
               let modifier = registry.modifier(named: name) {
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(baseValue, args, ctx)
                })
            }
            // `.blue.opacity(0.2)` / `.blue.gradient` — keep the chain opaque
            // for gateways. Calling the result refines the arguments.
            return .native(ChainedImplicitCall(base: baseValue, member: name, arguments: CallArguments()))

        case .hostFunction(let function):
            if name == "init" {
                return baseValue // `NSNumber.init(value:)` ≡ `NSNumber(value:)`
            }
            // Host TYPE names (Color, UIScreen, …) resolve to constructor
            // functions. The bridge may serve real statics (UIScreen.main);
            // user extensions add more (`extension ChatClient { static var
            // shared }`); otherwise they act like implicit members resolved
            // against the expected type at the gateway boundary.
            if let value = registry?.hostMember(name, on: HostTypeMarker(name: function.name)) {
                return value
            }
            if let symbol = hostExtensionSymbols[function.name],
               let value = try staticMember(name, of: symbol) {
                return value
            }
            return .implicitMember(name)

        case .int, .double, .bool, .host:
            // Inline scalars box on demand: `5.description`, `x.rounded()`,
            // and user Int/Double extensions all dispatch on the Any payload.
            let any = baseValue.hostPayload!
            if let casePath = any as? CasePathMarker, name == "extract",
               let symbol = casePath.enumSymbol, let caseName = casePath.caseName {
                // `casePath.extract(action)` → the payload (labeled tuple
                // for multi-payload cases) or nil on case mismatch.
                return .hostFunction(HostFunction(name: name) { args, _ in
                    var payloads: [RuntimeValue]?
                    if case .enumCase(let value)? = args.positional(0),
                       value.symbol === symbol, value.name == caseName {
                        payloads = value.associated
                    } else if case .host(let any)? = args.positional(0),
                              let call = any as? ImplicitMemberCall, call.name == caseName {
                        // Never-context-typed actions (a generic parameter
                        // slot) still carry the case shape.
                        payloads = call.arguments.arguments.map(\.value)
                    }
                    guard let payloads else { return .nilValue }
                    if payloads.count == 1 { return payloads[0] }
                    let labels = symbol.caseInfo(named: caseName)?.associatedLabels
                        ?? Array(repeating: nil, count: payloads.count)
                    return .native(TupleValue(labels: labels, values: payloads))
                })
            }
            if any is PublishedProjection {
                // Every pipeline stage chains another silent projection.
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(PublishedProjection())
                })
            }
            if let publisher = any as? ObjectWillChangePublisher {
                if name == "send" {
                    return .hostFunction(HostFunction(name: "send") { _, _ in
                        publisher.fire()
                        return .void
                    })
                }
                // Pipeline members (.debounce, .sink…) chain silently.
                return .native(PublishedProjection())
            }
            if let tuple = any as? TupleValue {
                // `(hrp: String, data: Data)` — member by label or index.
                let idx = Int(name) ?? tuple.labels.firstIndex(of: name) ?? -1
                if tuple.values.indices.contains(idx) { return tuple.values[idx] }
            }
            if let superRef = any as? SuperReference {
                let symbol = superRef.instance.symbol
                if let parentName = symbol.superclassName,
                   case .type(let parent)? = globals.lookup(parentName) {
                    // Interpreted superclass: dispatch methods/computed with
                    // self bound to the SAME instance (super dispatch).
                    if let method = parent.methods[name]?.first, let body = method.body {
                        return .closure(makeFunctionClosure(
                            method, body: body,
                            captured: selfEnvironment(.instance(superRef.instance))))
                    }
                    if let computed = parent.computedProperties[name] {
                        return try evaluateComputed(
                            computed, selfValue: .instance(superRef.instance), name: name)
                    }
                }
                // Host superclass (NSObject, UIViewController, …): super.init()
                // and lifecycle calls are inert — no interpreter analog.
                return .hostFunction(HostFunction(name: name) { _, _ in .void })
            }
            if let stub = any as? BindingStub {
                switch name {
                case "wrappedValue": return stub.box.value
                case "projectedValue": return baseValue
                case "animation", "transaction":
                    // `$flag.animation()` — presentation-side; the binding
                    // carries through unchanged.
                    return .hostFunction(HostFunction(name: name) { _, _ in baseValue })
                default:
                    // REAL members win over @dynamicMemberLookup, exactly as
                    // in compiled Swift: app `extension Binding { func load }`
                    // methods dispatch before any member projection
                    // (clean-architecture's Loadable bindings).
                    if let value = try hostExtensionMember(
                        name, candidates: ["Binding"], selfValue: baseValue) {
                        return value
                    }
                    // Binding is @dynamicMemberLookup: `$item.field` projects
                    // a binding to the field. Instance fields bind their own
                    // box (reference-backed); tuple elements write through
                    // the parent box; other members read through.
                    if case .instance(let inner) = stub.box.value,
                       let box = inner.box(for: inner.symbol.canonicalPropertyName(name)) {
                        return .native(BindingStub(box: box))
                    }
                    if let tuple = stub.box.value.tupleValue {
                        let index = Int(name) ?? tuple.labels.firstIndex(of: name) ?? -1
                        if tuple.values.indices.contains(index) {
                            let parent = stub.box
                            let element = Box(tuple.values[index])
                            element.onChange = {
                                guard let current = parent.value.tupleValue,
                                      current.values.indices.contains(index) else { return }
                                current.values[index] = element.value
                                parent.value = .native(current)
                            }
                            return .native(BindingStub(box: element))
                        }
                    }
                    // A binding over an UNKNOWABLE value projects a detached
                    // binding to the member chain (reads absorb, writes land
                    // in the detached box).
                    if case .host(let inner) = stub.box.value,
                       inner is InertCallable || inner is ChainedImplicitCall || inner is ImplicitMemberCall {
                        return .native(BindingStub(box: Box(.native(ChainedImplicitCall(
                            base: stub.box.value, member: name, arguments: CallArguments())))))
                    }
                    if case .implicitMember = stub.box.value {
                        return .native(BindingStub(box: Box(.native(ChainedImplicitCall(
                            base: stub.box.value, member: name, arguments: CallArguments())))))
                    }
                }
                switch name {
                case "append", "remove" where stub.box.value.arrayValue != nil:
                    // Projected-collection writes (`$results.append(x)` —
                    // the Realm/SwiftData binding idiom) mutate through the
                    // box, notifying like any state write.
                    let box = stub.box
                    let member = name
                    return .hostFunction(HostFunction(name: name) { args, _ in
                        guard var array = box.value.arrayValue,
                              let element = args.positional(0) else { return .void }
                        if member == "append" {
                            array.append(element)
                        } else {
                            array.removeAll { (try? Builtins.areEqual($0, element)) ?? false }
                        }
                        box.value = .native(array)
                        return .void
                    })
                default: break
                }
            }
            // User extensions of the host TYPE a value stands for win over
            // bridge-served members — they intentionally override our stubs
            // (`extension Color { var isDarkColor }` on a real Color,
            // `extension UIColor { … }` on a recorded UIColor node).
            // Core stubs the bridge can't name map explicitly (Binding).
            var extensionCandidates: [String] = []
            if let typeName = registry?.hostTypeName(of: any) {
                extensionCandidates.append(typeName)
            }
            if any is BindingStub { extensionCandidates.append("Binding") }
            if !extensionCandidates.isEmpty,
               let value = try hostExtensionMember(
                   name, candidates: extensionCandidates, selfValue: baseValue) {
                return value
            }
            // The bridge gets first refusal on host natives (GeometryProxy,
            // CGRect, and static chains like UIScreen.main / DispatchQueue.main).
            if let value = registry?.hostMember(name, on: any) {
                return value
            }
            if any is HostTypeMarker {
                // `Color.red` ≡ `.red` — resolved by expected type at gateways.
                return .implicitMember(name)
            }
            if let projection = any as? ModelProjection {
                if let box = projection.model.box(for: name) {
                    return .native(BindingStub(box: box))
                }
                // Computed properties with setters bind through their
                // accessors (Observation's access/withMutation idiom:
                // `$store.sortType` where sortType wraps _sortType).
                if let computed = projection.model.symbol.computedProperties[name],
                   let setter = computed.setter {
                    let model = projection.model
                    let seed = try evaluateComputed(computed, selfValue: .instance(model), name: name)
                    let box = Box(seed)
                    box.onChange = { [weak self] in
                        guard let self else { return }
                        let env = self.selfEnvironment(.instance(model))
                        env.define(setter.parameterName, box.value)
                        _ = try? self.executeBlock(setter.body, in: env)
                    }
                    return .native(BindingStub(box: box))
                }
                // `$store.scope(state:action:)` — TCA's bindable scoping:
                // the model's own MEMBER dispatches (the projection's
                // binding-ness only matters for write-back, which absorbs).
                if let member = try instanceMember(name, on: projection.model) {
                    return member
                }
                if assumesCompiledImports {
                    // @dynamicMemberLookup projections (TCA's `$store.filter`
                    // rides Store's dynamic member into State) — the
                    // un-modeled lookup absorbs to a fresh binding.
                    return .native(BindingStub(box: Box(.native(ChainedImplicitCall(
                        base: .instance(projection.model), member: name,
                        arguments: CallArguments())))))
                }
                throw error(node, "'$\(projection.model.symbol.name)' has no stored property '\(name)'")
            }
            if let tuple = any as? TupleValue, let value = tuple.value(for: name) {
                return value
            }
            if let value = try nativeMember(name, on: any) {
                return value
            }
            if let value = try hostExtensionMember(name, candidates: hostCandidates(for: any), selfValue: baseValue) {
                return value
            }
            if let registry, registry.isViewValue(baseValue), let modifier = registry.modifier(named: name) {
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(baseValue, args, ctx)
                })
            }
            // Members on unresolved markers extend the chain instead of dying
            // here — `.easeInOut(duration: 0.3).delay(0.2)` folds at the
            // gateway boundary where the expected type is known.
            if any is ImplicitMemberCall || any is ChainedImplicitCall {
                // `.init(width: 100, height: 120).height` — reading a member
                // that matches a labeled constructor argument returns it
                // (memberwise read-back on an unresolved init marker).
                if let call = any as? ImplicitMemberCall, call.name == "init",
                   let argument = call.arguments.labeled(name) {
                    return argument
                }
                // Wrapper-storage markers behave as their wrapped value:
                // `.init(initialValue: Model(…)).statusesState` dispatches
                // onto the model (the storage IS the value doctrine).
                if let call = any as? ImplicitMemberCall, call.name == "init",
                   let wrapped = call.arguments.labeled("initialValue")
                    ?? call.arguments.labeled("wrappedValue") {
                    return try accessMember(name, on: wrapped, node: node, env: env)
                }
                return .native(ChainedImplicitCall(base: baseValue, member: name, arguments: CallArguments()))
            }
            if name == "description" || name == "debugDescription" {
                // CustomStringConvertible: every stdlib value prints
                // (`store.count.description` — Int, Double, Bool, …).
                return .native(baseValue.stringValue ?? baseValue.stringified)
            }
            if name == "map" || name == "flatMap" {
                // Optional.map on a non-nil value — optionals ARE the value
                // here, so `url.map { … }` applies the transform to it
                // (collections and strings matched their own map earlier).
                // Function REFERENCES (`​.flatMap(Bundle.init(url:))`) apply
                // like closures; unresolvable transforms absorb.
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    if let closure = args.firstUnlabeledClosure {
                        return try ctx.callClosure(closure, arguments: [baseValue])
                    }
                    if case .hostFunction(let fn)? = args.positional(0) {
                        return try fn.invoke(
                            CallArguments(arguments: [.init(label: nil, value: baseValue)]), ctx)
                    }
                    if case .closure(let closure)? = args.positional(0) {
                        return try ctx.callClosure(closure, arguments: [baseValue])
                    }
                    return .native(ChainedImplicitCall(
                        base: baseValue, member: name, arguments: args))
                })
            }
            if let caught = any as? RuntimeError,
               name == "localizedDescription" || name == "description" || name == "message" {
                // A caught interpreter error in an interpreted `catch`: its
                // message IS what a compiled error would surface (the last
                // absorb-census entry — now served for real).
                return .native(caught.message)
            }
            if assumesCompiledImports {
                // Compiled sources: an unknown member on a NATIVE that
                // survived every dispatch (host members, extensions, stdlib)
                // is an UNMERGED-package extension (`query.isReallyEmpty`
                // from a utility dependency) — absorbs, exactly like the
                // interpreted-instance rule.
                recordAbsorbedHostMember(type: String(describing: type(of: any)), member: name)
                return .native(ChainedImplicitCall(
                    base: baseValue, member: name, arguments: CallArguments()))
            }
            throw error(node, "unsupported member '\(name)' on \(type(of: any))")

        case .void:
            if assumesCompiledImports {
                // A () in member position is a SYNTHESIS gap — a DI-wrapper
                // property nothing injected (`@Dependency(\.analytics)` on a
                // non-view class), a compiled call whose value we couldn't
                // model. The device had something real there: absorb.
                return .native(ChainedImplicitCall(
                    base: .implicitMember(name), member: name, arguments: CallArguments()))
            }
            throw error(node, "cannot access member '\(name)' on \(baseValue.stringified)")

        default:
            throw error(node, "cannot access member '\(name)' on \(baseValue.stringified)")
        }
    }

    /// Static property initializers reference bare sibling statics
    /// (`static let network = custom(category: "network")`).
    private func staticInitEnvironment(for symbol: StructSymbol) -> Environment {
        selfEnvironment(.type(symbol))
    }

    private func staticInitEnvironment(for symbol: EnumSymbol) -> Environment {
        selfEnvironment(.enumType(symbol))
    }

    func staticMember(_ name: String, of symbol: StructSymbol) throws -> RuntimeValue? {
        if let nested = symbol.nestedTypes[name] { return nested }
        if let cached = symbol.staticCache[name] { return cached }
        if let property = symbol.staticProperties[name] {
            let raw = try evaluate(property.initializer, in: staticInitEnvironment(for: symbol))
            let value = try resolveAnnotated(raw, annotation: property.typeAnnotation)
            symbol.staticCache[name] = value
            return value
        }
        if let computed = symbol.staticComputedProperties[name] {
            // `static var currentMonth: Date { … }` — evaluated fresh each
            // read (no caching: getters may depend on time or other state);
            // self is the TYPE, so bare sibling statics resolve.
            return try evaluateComputed(computed, selfValue: .type(symbol), name: name)
        }
        if let overloads = symbol.staticMethods[name], let first = overloads.first {
            // Static context: `self`/`Self` and bare sibling statics
            // resolve. Within an overload SET the running declaration never
            // re-enters itself (Logger.log's autoclosure convenience
            // delegating to its closure-taking sibling).
            let method = overloads.count > 1
                ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? first)
                : first
            if let body = method.body {
                return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.type(symbol))))
            }
        }
        if let attribute = symbol.staticWrapped[name],
           case .type(let wrapperSymbol)? = globals.lookup(attribute.attributeName.trimmedDescription),
           wrapperSymbol.computedProperties["wrappedValue"] != nil
               || wrapperSymbol.storedProperty(named: "wrappedValue") != nil {
            // Custom-wrapper static: the backing wrapper instance builds
            // once from the attribute's arguments; every read runs its
            // wrappedValue getter (AppUserDefaults.alwaysOriginalTitle).
            let backingKey = "__wrapper_" + name
            let backing: RuntimeValue
            if let cached = symbol.staticCache[backingKey] {
                backing = cached
            } else {
                var arguments: [CallArguments.Argument] = []
                if case .argumentList(let list)? = attribute.arguments {
                    for element in list {
                        arguments.append(.init(
                            label: element.label?.text,
                            value: try evaluate(element.expression, in: globals)))
                    }
                }
                backing = try instantiate(
                    wrapperSymbol, with: CallArguments(arguments: arguments), node: nil)
                symbol.staticCache[backingKey] = backing
            }
            if case .instance(let wrapper) = backing {
                return try instanceMember("wrappedValue", on: wrapper)
            }
        }
        if symbol.staticUninitialized.contains(name) { return .nilValue }
        return nil
    }

    func staticMember(_ name: String, of symbol: EnumSymbol) throws -> RuntimeValue? {
        // Own nested types shadow same-named globals inside the body —
        // the struct-path doctrine applied to enum namespaces.
        if let nested = symbol.nestedTypes[name] { return nested }
        if let cached = symbol.staticCache[name] { return cached }
        if let property = symbol.staticProperties[name] {
            let raw = try evaluate(property.initializer, in: staticInitEnvironment(for: symbol))
            let value = try resolveAnnotated(raw, annotation: property.typeAnnotation)
            symbol.staticCache[name] = value
            return value
        }
        if let computed = symbol.staticComputedProperties[name] {
            return try evaluateComputed(computed, selfValue: .enumType(symbol), name: name)
        }
        if let overloads = symbol.staticMethods[name], let first = overloads.first {
            // A bare reference from INSIDE the running argful method reads
            // past it — `static func allCases(for:)` whose body says
            // `allCases.filter` means the SYNTHESIZED CaseIterable array.
            let method = overloads.first { !activeFunctionBodies.contains($0.id) } ?? first
            if activeFunctionBodies.contains(method.id), name == "allCases" {
                let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                    RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
                }
                return .native(all)
            }
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumType(symbol))))
        }
        if name == "allCases", symbol.conformances.contains("CaseIterable") {
            let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
            }
            return .native(all)
        }
        return nil
    }

    // MARK: - Calls

    static let cStdlibNames: Set<String> = [
        "malloc", "calloc", "realloc", "free", "memcpy", "memmove", "memset",
        "strlen", "strcmp", "strncmp", "strcpy", "strdup",
        // Process-control calls in merged helper-tool files: interpreted
        // execution continues (the app target never runs them at launch).
        "exit", "abort", "usleep", "sleep",
        // sysctl/process-info family.
        "sysctl", "sysctlbyname", "getpid", "getppid", "getenv", "setenv",
        "unsetenv", "getuid", "geteuid",
    ]

    /// Identifier shapes that read as C imports (snake_case, leading
    /// underscore, or the known stdlib list) — these absorb via the C
    /// branch and must never be claimed by the modifier rescue.
    static func looksLikeCImport(_ name: String) -> Bool {
        cStdlibNames.contains(name)
            || (name.contains("_") && name.first?.isLowercase == true)
            || (name.hasPrefix("_") && name.dropFirst().first?.isLowercase == true)
    }

    /// Runtime type test for `is`: primitives and interpreted symbols check
    /// truly; host natives match the registry's type name; markers and nil
    /// read false.
    func valueIsType(_ value: RuntimeValue, _ rawType: String) -> Bool {
        var typeName = rawType.trimmingCharacters(in: .whitespaces)
        if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }
        if let range = value.rangeValue, let annotation = Self.rangeAnnotation(typeName) {
            guard range.matchesNominalShape(annotation.name) else { return false }
            let bounds = [range.lowerBound, range.upperBound].compactMap { $0 }
            if Self.doubleFamilyTypeNames.contains(annotation.bound) {
                return bounds.allSatisfy { $0.doubleValue != nil }
            }
            if annotation.bound == "Int" { return bounds.allSatisfy { $0.intValue != nil } }
            if annotation.bound == "String" { return bounds.allSatisfy { $0.stringValue != nil } }
            if annotation.bound == "Date" {
                return bounds.allSatisfy { value in
                    if case .host(let any) = value { return any is Date }
                    return false
                }
            }
            if annotation.bound == "String.Index" {
                return bounds.allSatisfy { value in
                    if case .host(let any) = value { return any is String.Index }
                    return false
                }
            }
            return false
        }
        if let angle = typeName.firstIndex(of: "<") { typeName = String(typeName[..<angle]) }
        if typeName == "Any" || typeName == "AnyObject" { return !value.isNil }
        if value.isNil { return false }
        switch value {
        case .int: return ["Int", "Double", "CGFloat", "TimeInterval", "NSNumber"].contains(typeName)
        case .double: return ["Double", "CGFloat", "TimeInterval", "Float", "NSNumber"].contains(typeName)
        case .bool: return typeName == "Bool" || typeName == "NSNumber"
        case .instance(let instance):
            var symbol: StructSymbol? = instance.symbol
            while let current = symbol {
                if current.name == typeName { return true }
                if current.conformances.contains(where: { conformance in
                    var seen = Set<String>()
                    return protocolReaches(conformance, target: typeName, seen: &seen)
                }) { return true }
                guard let superName = current.superclassName,
                      case .type(let parent)? = globals.lookup(superName) else { break }
                symbol = parent
            }
            return false
        case .enumCase(let caseValue):
            if caseValue.symbol.name == typeName { return true }
            return caseValue.symbol.conformances.contains { conformance in
                var seen = Set<String>()
                return protocolReaches(conformance, target: typeName, seen: &seen)
            }
        case .host(let any):
            if any is String || any is NSString { return ["String", "NSString"].contains(typeName) }
            if any is Date { return ["Date", "NSDate"].contains(typeName) }
            if any is URL { return ["URL", "NSURL"].contains(typeName) }
            if any is Data { return ["Data", "NSData"].contains(typeName) }
            if any is [RuntimeValue] { return ["Array", "NSArray"].contains(typeName) || typeName.hasPrefix("[") }
            if any is DictValue { return ["Dictionary", "NSDictionary"].contains(typeName) || typeName.hasPrefix("[") }
            if any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                return false // unknowable: fresh state IS nothing yet
            }
            return registry?.hostTypeName(of: any) == typeName
        default:
            return false
        }
    }

    /// A custom ViewModifier applies by RUNNING its body(content:) — real
    /// semantics for both spellings (`.modifier(m)` and
    /// `ModifiedContent(content:modifier:)`).
    func applyViewModifier(
        _ modifier: Instance, to content: RuntimeValue, node: Syntax?
    ) throws -> RuntimeValue {
        guard let overloads = modifier.symbol.methods["body"], let method = overloads.first,
              let body = method.body else {
            return content // bodyless conformer: identity
        }
        let closure = makeFunctionClosure(
            method, body: body, captured: selfEnvironment(.instance(modifier)))
        return try callWithArguments(
            closure,
            args: CallArguments(arguments: [.init(label: "content", value: content)]),
            node: node)
    }

    func evaluateCall(_ call: FunctionCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        // `ModifiedContent(content: self, modifier: TitleFont(size: 16))` —
        // the explicit ViewModifier application (MovieSwiftUI's titleStyle).
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "ModifiedContent",
           env.box(for: "ModifiedContent") == nil, globals.lookup("ModifiedContent") == nil {
            let args = try collectArguments(of: call, in: env)
            if let content = args.labeled("content"),
               case .instance(let modifier)? = args.labeled("modifier") {
                return try applyViewModifier(modifier, to: content, node: Syntax(call))
            }
        }
        // `[Index]()` / `[String: Int]()` — typed empty containers.
        if call.calledExpression.is(ArrayExprSyntax.self) {
            if call.arguments.isEmpty { return .native([RuntimeValue]()) }
            // `[CChar](repeating: 0, count: n)` — the typed-array ctor.
            let args = try collectArguments(of: call, in: env)
            if let element = args.labeled("repeating"), let count = args.labeled("count")?.intValue {
                return .native([RuntimeValue](repeating: element, count: max(0, count)))
            }
            if let array = args.positional(0)?.arrayValue { return .native(array) }
            return .native([RuntimeValue]())
        }
        if call.calledExpression.is(DictionaryExprSyntax.self), call.arguments.isEmpty {
            return .native(DictValue())
        }
        // `.system(size: 40)` — implicit member call, resolved later by a gateway.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil {
            let args = try collectArguments(of: call, in: env)
            return .native(ImplicitMemberCall(name: member.declName.baseName.text, arguments: args))
        }
        // Methods that mutate collections in place, and property/method pairs
        // like `first` / `first(where:)`, need the base handled specially.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let baseExpr = member.base {
            let name = member.declName.baseName.text
            if let result = try specialMemberCall(name, base: baseExpr, call: call, in: env) {
                return result
            }
            let baseValue = try evaluate(baseExpr, in: env)
            // OVERLOADED methods pick by call shape ('func error(_: Error)'
            // vs 'error(localized:args:)') — bare-name member access can't.
            if case .instance(let instance) = baseValue,
               let overloads = instance.symbol.methods[name],
               overloads.count > 1 || instance.symbol.computedProperties[name] != nil {
                let args = try collectArguments(of: call, in: env)
                let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
                if available.isEmpty {
                    // Every overload is already running (send#StoreTask ↔
                    // send#Task mutual delegation): the device's return-type
                    // dispatch found a runtime path we can't — absorb.
                    return .native(ChainedImplicitCall(
                        base: baseValue, member: name, arguments: args))
                }
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.instance(instance)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            // STATIC overloads pick by call shape too:
            // KioskRow.label(_:systemSymbol:) vs label(_:icon:).
            if case .type(let symbol) = baseValue,
               let overloads = symbol.staticMethods[name], overloads.count > 1 {
                let args = try collectArguments(of: call, in: env)
                let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: baseValue, member: name, arguments: args))
                }
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.type(symbol)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            if case .enumType(let symbol) = baseValue,
               let overloads = symbol.staticMethods[name], !overloads.isEmpty,
               !call.arguments.isEmpty || call.trailingClosure != nil
                   || symbol.staticComputedProperties[name] == nil {
                // Static-method CALLS dispatch even for single overloads —
                // `Sort.allCases(for:)` must not invoke the synthesized
                // CaseIterable ARRAY (the collision rule at call sites).
                let args = try collectArguments(of: call, in: env)
                let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: baseValue, member: name, arguments: args))
                }
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.enumType(symbol)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            let callee = try accessMember(name, on: baseValue, node: member, env: env)
            let args = try collectArguments(of: call, in: env)
            // A nil PROPERTY at a call site never throws (nil-call absorbs),
            // so the collision rescue below can't fire — pre-check it. The
            // property `timeZone.nextDaylightSavingTimeTransition` is
            // honestly nil (a zone with no future DST), but the call shape
            // names the METHOD form (after:), which answers for real.
            if case .nilValue = callee, let any = baseValue.hostPayload,
               let method = registry?.hostMethod(name, on: any) {
                return try invoke(method, with: args, node: call)
            }
            do {
                return try invoke(callee, with: args, node: call)
            } catch let bindingError as RuntimeError
                where !bindingError.fatal
                    && (bindingError.message.hasPrefix("missing argument")
                        || bindingError.message.hasSuffix("is not callable")) {
                // PROPERTY/METHOD collision at a CALL site: the type's own
                // computed property shadowed a PROTOCOL-EXTENSION method
                // (Status's `var isHidden` vs AnyStatus's `isHidden(in:)`)
                // — dispatch the method, as overload resolution would.
                if case .instance(let instance) = baseValue {
                    for conformance in transitiveConformances(of: instance.symbol) {
                        guard let proto = hostExtensionSymbols[conformance],
                              let overloads = proto.methods[name] else { continue }
                        let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
                        // Only a FITTING overload rescues — a wrong-shaped
                        // sibling must fall through to the modifier retry.
                        guard let method = chooseFunction(from: available, for: args),
                              let body = method.body else { continue }
                        let closure = makeFunctionClosure(
                            method, body: body, captured: selfEnvironment(.instance(instance)))
                        return try invoke(.closure(closure), with: args, node: call)
                    }
                }
                // The SAME collision on a HOST value: the generated table's
                // property answered the access (`url.query` → "x=1&y=2"),
                // but the call shape names the METHOD
                // (`query(percentEncoded:)`) — re-dispatch through the
                // methods-only table, as native overload resolution would.
                if let any = baseValue.hostPayload,
                   let method = registry?.hostMethod(name, on: any) {
                    return try invoke(method, with: args, node: call)
                }
                // A user extension OR a same-named PROPERTY can shadow a
                // built-in modifier (`extension View { func offset(
                // coordinateSpace:…) }`; `var offset: CGFloat` on a view
                // struct vs `.offset(y:)`). Binding/invocation fails before
                // any body runs, so retrying through the modifier table is
                // safe.
                guard let registry, let modifier = registry.modifier(named: name),
                      let target = modifierTarget(for: baseValue) else {
                    throw bindingError
                }
                do {
                    return try modifier.apply(target, args, self)
                } catch let e as RuntimeError where e.line == 0 {
                    throw error(call, e.message)
                }
            }
        }
        // Unqualified overloaded calls inside the type's own body.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           env.box(for: ref.baseName.text, before: globals) == nil {
            let name = ref.baseName.text
            // Bare `path(percentEncoded:)` inside a URL extension — the
            // METHOD/property collision, implicit-self flavor.
            if name == "path",
               call.arguments.contains(where: { $0.label?.text == "percentEncoded" }),
               let url = env.lookup("self")?.hostPayload as? URL {
                let args = try collectArguments(of: call, in: env)
                return .native(url.path(percentEncoded: args.labeled("percentEncoded")?.boolValue ?? true))
            }
            // GLOBAL function overloads pick by call shape with the
            // running-declaration exclusion (L10n's variadic form delegates
            // to its single-argument sibling).
            if let overloads = globalFunctionOverloads[name], overloads.count > 1,
               env.box(for: name, before: globals) == nil {
                let args = try collectArguments(of: call, in: env)
                let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: .implicitMember(name), member: "call", arguments: args))
                }
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(method, body: body, captured: globals)
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            if case .instance(let instance)? = env.lookup("self"),
               let overloads = instance.symbol.methods[name],
               overloads.count > 1 || instance.symbol.computedProperties[name] != nil {
                let args = try collectArguments(of: call, in: env)
                let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: .instance(instance), member: name, arguments: args))
                }
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.instance(instance)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            if case .type(let symbol)? = env.lookup("self"),
               let overloads = symbol.staticMethods[name], overloads.count > 1 {
                let args = try collectArguments(of: call, in: env)
                let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: .type(symbol), member: name, arguments: args))
                }
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.type(symbol)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
        }
        let callee = try evaluate(call.calledExpression, in: env)
        let args = try collectArguments(of: call, in: env)
        return try invoke(callee, with: args, node: call)
    }

    /// The value a retried modifier applies to: view values directly,
    /// view/shape-conforming instances wrapped renderable.
    private func modifierTarget(for value: RuntimeValue) -> RuntimeValue? {
        guard let registry else { return nil }
        if registry.isViewValue(value) { return value }
        if case .instance(let instance) = value,
           instance.symbol.rendersLikeView
            || instance.symbol.conformsToShape || instance.symbol.conformsToLayout {
            return registry.makeRenderable(instance: instance, interpreter: self)
        }
        return nil
    }

    /// Mutating collection methods (`items.append(x)`) resolve the base as an
    /// lvalue; `first(where:)`/`last(where:)` collide with the same-named
    /// properties. Returns nil to fall through to normal dispatch.
    private func specialMemberCall(
        _ name: String,
        base: ExprSyntax,
        call: FunctionCallExprSyntax,
        in env: Environment
    ) throws -> RuntimeValue? {
        // `.modifier(TitleFont(size: 16))` — a custom ViewModifier applies
        // by RUNNING its body(content:), with the modifier's OWN
        // @Environment/@State properties injected first (uninjected reads
        // were voids — the iteration-198 revert). Only the strict
        // ViewModifier shape dispatches: declared conformance AND a body
        // method whose single parameter is the content.
        if name == "modifier" {
            let args = try collectArguments(of: call, in: env)
            if case .instance(let modifier)? = args.positional(0),
               modifier.symbol.conformances.contains("ViewModifier"),
               let overloads = modifier.symbol.methods["body"],
               let method = overloads.first, method.body != nil,
               method.signature.parameterClause.parameters.count == 1 {
                let baseValue = try evaluate(base, in: env)
                injectEnvironmentValues(into: modifier, values: [:])
                return try applyViewModifier(modifier, to: baseValue, node: Syntax(call))
            }
        }
        // MUTATING methods on ENUM receivers through writable lvalues:
        // `wrappedValue.setIsLoading(cancelBag:)` — the method runs on a
        // copy whose `self` reassignments write BACK through the lvalue
        // (value semantics; through a Binding this fires the set-closure
        // exactly once, like the native read-modify-write).
        if let target = try? resolveLValue(base, in: env),
           let current = try? target.read(self),
           case .enumCase(let receiver) = current,
           let overloads = receiver.symbol.methods[name],
           let method = overloads.first(where: { declared in
               declared.modifiers.contains { $0.name.text == "mutating" }
           }),
           let body = method.body {
            let args = try collectArguments(of: call, in: env)
            let selfEnv = selfEnvironment(.enumCase(receiver))
            let closure = makeFunctionClosure(method, body: body, captured: selfEnv)
            let result = try callWithArguments(closure, args: args, node: Syntax(call))
            if let newSelf = selfEnv.box(for: "self")?.value {
                // `self = .loaded(last)` rides as a marker — the receiver's
                // own symbol is the annotation that resolves it to a case.
                let resolved = try resolveAnnotated(newSelf, typeName: receiver.symbol.name)
                try relocating(call) { try target.write(resolved, self) }
            }
            return result
        }
        // Bool.toggle() — ubiquitous in SwiftUI code (`show.toggle()`); writes
        // through the lvalue so @State/@Published notification fires.
        if name == "toggle",
           let target = try? resolveLValue(base, in: env),
           let current = try target.read(self).boolValue {
            _ = try collectArguments(of: call, in: env) // evaluate (empty) args for side effects
            try relocating(call) { try target.write(.native(!current), self) }
            return .void
        }

        // `url.path(percentEncoded:)` — the modern METHOD collides with the
        // legacy `path` PROPERTY; the call shape resolves here (the
        // first(where:) precedent). Only URL bases match; the labeled-arg
        // guard keeps other `path(…)` calls off this route.
        if name == "path",
           call.arguments.contains(where: { $0.label?.text == "percentEncoded" }),
           case .host(let any) = try evaluate(base, in: env),
           let url = any as? URL {
            let args = try collectArguments(of: call, in: env)
            let encoded = args.labeled("percentEncoded")?.boolValue ?? true
            return .native(url.path(percentEncoded: encoded))
        }

        // Mutating String members write through the lvalue:
        // `text.replaceSubrange(range, with: "…")`.
        if name == "replaceSubrange",
           let target = try? resolveLValue(base, in: env),
           case .host(let existingAny) = try target.read(self),
           var text = existingAny as? String {
            let args = try collectArguments(of: call, in: env)
            guard let replacement = args.labeled("with")?.stringValue,
                  let range = args.positional(0)?.rangeValue else {
                throw error(call, "replaceSubrange needs a range and 'with:'")
            }
            text.replaceSubrange(try stringSlice(range, in: text, node: call), with: replacement)
            try relocating(call) { try target.write(.native(text), self) }
            return .void
        }

        // Mutating URL members write through the lvalue (value semantics):
        // `url.append(path:)` / `url.appendPathComponent(_:)`.
        if name == "append" || name == "appendPathComponent",
           let target = try? resolveLValue(base, in: env),
           case .host(let existingAny) = try target.read(self),
           let url = existingAny as? URL {
            let args = try collectArguments(of: call, in: env)
            guard let component = (args.labeled("path") ?? args.labeled("component")
                ?? args.positional(0))?.stringValue else {
                throw error(call, "append needs a path component")
            }
            var updated = url
            updated.append(path: component)
            try relocating(call) { try target.write(.native(updated), self) }
            return .void
        }

        // Data mutations write through the lvalue (value semantics):
        // `data.append(other)` / `data.append(byte)`.
        if name == "append",
           let target = try? resolveLValue(base, in: env),
           case .host(let existingAny) = try target.read(self),
           var bytes = existingAny as? Data {
            let args = try collectArguments(of: call, in: env)
            guard let value = args.positional(0) else {
                throw error(call, "append needs a value")
            }
            if case .host(let addAny) = value, let more = addAny as? Data {
                bytes.append(more)
            } else if let byte = value.intValue {
                bytes.append(UInt8(truncatingIfNeeded: byte))
            } else if let array = value.arrayValue {
                bytes.append(contentsOf: array.compactMap { $0.intValue.map { UInt8(truncatingIfNeeded: $0) } })
            } else {
                throw error(call, "cannot append \(value.stringified) to Data")
            }
            try relocating(call) { try target.write(.native(bytes), self) }
            return .void
        }

        // `str.size(withAttributes:)` — the NSString measurement API, served
        // by the bridge (real font metrics). Dispatch is call-label-aware
        // because user extensions commonly define their own `size(_ font:)`
        // wrapper around it, and plain member access must keep resolving to
        // that extension.
        if name == "size", call.arguments.first?.label?.text == "withAttributes" {
            let baseValue = try evaluate(base, in: env)
            if let string = baseValue.stringValue,
               case .hostFunction(let measure)? = registry?.hostMember("sizeWithAttributes", on: string as Any) {
                let args = try collectArguments(of: call, in: env)
                do {
                    return try measure.invoke(args, self)
                } catch let e as RuntimeError where e.line == 0 {
                    throw error(call, e.message)
                }
            }
        }

        // `text.count(where: { … })` — count-as-function (the property wins
        // for plain `.count`; the call form is label-dispatched here).
        if name == "count", call.arguments.first?.label?.text == "where" {
            let baseValue = try evaluate(base, in: env)
            let args = try collectArguments(of: call, in: env)
            guard let closure = args.closure(labeled: "where") else {
                throw error(call, "count(where:) needs a closure")
            }
            var elements: [RuntimeValue] = []
            if let string = baseValue.stringValue {
                elements = string.map { .native(String($0)) }
            } else if let array = baseValue.arrayValue {
                elements = array
            }
            var matched = 0
            for element in elements where try callClosure(closure, arguments: [element]).boolValue == true {
                matched += 1
            }
            return .native(matched)
        }

        // `code.append("7")` / `append(contentsOf:)` — mutating String
        // append through the lvalue.
        if name == "append",
           let target = try? resolveLValue(base, in: env),
           let current = try target.read(self).stringValue {
            let args = try collectArguments(of: call, in: env)
            guard let argument = args.labeled("contentsOf") ?? args.positional(0), !argument.isNil else {
                throw error(call, "String.append needs a value")
            }
            let suffix = argument.stringValue ?? argument.stringified
            try relocating(call) { try target.write(.native(current + suffix), self) }
            return .void
        }
        // `text.insert(char, at: index)` — String insertion at a String.Index.
        if name == "insert",
           call.arguments.contains(where: { $0.label?.text == "at" }),
           let target = try? resolveLValue(base, in: env),
           let current = try target.read(self).stringValue {
            let args = try collectArguments(of: call, in: env)
            guard let element = args.positional(0), !element.isNil,
                  case .host(let idxAny)? = args.labeled("at"),
                  let index = idxAny as? Swift.String.Index else {
                throw error(call, "String.insert needs a value and an at: String.Index")
            }
            var copy = current
            let clamped = min(index, copy.endIndex)
            copy.insert(contentsOf: element.stringValue ?? element.stringified, at: clamped)
            try relocating(call) { try target.write(.native(copy), self) }
            return .void
        }

        let mutating = ["append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "sort"]
        if mutating.contains(name),
           let target = try? resolveLValue(base, in: env),
           var array = try target.read(self).arrayValue {
            let args = try collectArguments(of: call, in: env)
            // `items.append(.init())` — the element type comes from the
            // target property's `[Type]` annotation.
            let elementType = target.annotatedElementType()
            func resolved(_ value: RuntimeValue) throws -> RuntimeValue {
                guard let elementType else { return value }
                return try resolveAnnotated(value, typeName: elementType)
            }
            switch name {
            case "append":
                if let contents = args.labeled("contentsOf")?.arrayValue {
                    array.append(contentsOf: try contents.map(resolved))
                } else if let value = args.positional(0) {
                    array.append(try resolved(value))
                } else {
                    throw error(call, "append needs a value")
                }
            case "insert":
                // SET-typed storage synthesizes as an array: one-argument
                // `insert(member)` (no at:) is Set.insert — append when
                // absent, answering (inserted, memberAfterInsert).
                if args.labeled("at") == nil, let member = args.positional(0) {
                    let value = try resolved(member)
                    let present = try array.contains { try Builtins.areEqual($0, value) }
                    if !present { array.append(value) }
                    try relocating(call) { try target.write(.native(array), self) }
                    return .native(TupleValue(
                        labels: ["inserted", "memberAfterInsert"],
                        values: [.bool(!present), value]))
                }
                guard let value = args.positional(0), let index = args.labeled("at")?.intValue,
                      index >= 0, index <= array.count else {
                    throw error(call, "insert needs a value and a valid at: index")
                }
                array.insert(try resolved(value), at: index)
            case "remove":
                // `remove(atOffsets:)` — SwiftUI's IndexSet form (arrives as
                // an index array): delete DESCENDING so offsets stay valid.
                if let offsets = args.labeled("atOffsets")?.arrayValue {
                    let indices = offsets.compactMap(\.intValue).sorted(by: >)
                    for index in indices where array.indices.contains(index) {
                        array.remove(at: index)
                    }
                    try relocating(call) { try target.write(.native(array), self) }
                    return .void
                }
                guard let index = args.labeled("at")?.intValue, array.indices.contains(index) else {
                    throw error(call, "remove(at:) index out of range")
                }
                let removed = array.remove(at: index)
                try relocating(call) { try target.write(.native(array), self) }
                return removed
            case "removeAll":
                if let closure = args.closure(labeled: "where") {
                    var kept: [RuntimeValue] = []
                    for element in array where try callClosure(closure, arguments: [element]).boolValue != true {
                        kept.append(element)
                    }
                    array = kept
                } else {
                    array = []
                }
            case "removeFirst":
                guard !array.isEmpty else { throw error(call, "removeFirst on an empty array") }
                let removed = array.removeFirst()
                try relocating(call) { try target.write(.native(array), self) }
                return removed
            case "removeLast":
                guard !array.isEmpty else { throw error(call, "removeLast on an empty array") }
                let removed = array.removeLast()
                try relocating(call) { try target.write(.native(array), self) }
                return removed
            case "sort":
                var failure: Error?
                array.sort { a, b in
                    if failure != nil { return false }
                    // Declared `static func <` (Comparable) dispatches, like
                    // infix and the XCTAssert gateways.
                    do { return try evaluateBinary("<", a, b).boolValue == true }
                    catch { failure = error; return false }
                }
                if let failure { throw failure }
            default:
                return nil
            }
            try relocating(call) { try target.write(.native(array), self) }
            return .void
        }

        if name == "first" || name == "last" {
            let baseValue = try evaluate(base, in: env)
            let array = baseValue.arrayValue ?? baseValue.rangeValue?.integerValues()
            if let array {
                let args = try collectArguments(of: call, in: env)
                if let closure = args.closure(labeled: "where") ?? args.firstUnlabeledClosure {
                    let ordered = name == "last" ? Array(array.reversed()) : array
                    for element in ordered where try callClosure(closure, arguments: [element]).boolValue == true {
                        return element
                    }
                    return .nilValue
                }
            }
        }
        return nil
    }

    func collectArguments(of call: FunctionCallExprSyntax, in env: Environment) throws -> CallArguments {
        var arguments: [CallArguments.Argument] = []
        for labeled in call.arguments {
            arguments.append(.init(label: labeled.label?.text, value: try evaluate(labeled.expression, in: env)))
        }
        if let trailing = call.trailingClosure {
            arguments.append(.init(label: nil, value: .closure(makeClosure(trailing, in: env)), isTrailing: true))
        }
        for extra in call.additionalTrailingClosures {
            arguments.append(.init(label: extra.label.text, value: .closure(makeClosure(extra.closure, in: env)), isTrailing: true))
        }
        return CallArguments(arguments: arguments)
    }

    /// A host-extension init fits only when labels align AND every
    /// argument's RUNTIME type satisfies the parameter annotation.
    private func extensionInitFits(_ decl: InitializerDeclSyntax, args: CallArguments) -> Bool {
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
            return .nilValue // optional chaining through a nil method
        case .instance(let instance) where instance.symbol.methods["callAsFunction"] != nil:
            // SwiftUI action values (`openWindow(id:)`, OpenCocoaWindowAction)
            // — instances invoke through callAsFunction.
            if let overloads = instance.symbol.methods["callAsFunction"],
               let method = chooseFunction(from: overloads, for: args) ?? overloads.first,
               let body = method.body {
                let closure = makeFunctionClosure(
                    method, body: body, captured: selfEnvironment(.instance(instance)))
                return try callWithArguments(closure, args: args, node: Syntax(node))
            }
            return .void
        case .type(let symbol):
            // A `Layout` conformer called with a content closure is the
            // callAsFunction sugar (`_Layout(width:…) { views }`): headless
            // layout is pure geometry — the CONTENT is the rendered view.
            if symbol.conformances.contains("Layout"),
               let content = args.firstUnlabeledClosure {
                return try groupViews(callBuilderClosure(content, arguments: []).map { $0 })
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
                return symbol.cases
                    .first { (try? Builtins.areEqual($0.rawValue, raw)) == true }
                    .map { RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name)) }
                    ?? .nilValue
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
                return try resolveAnnotated(assigned, typeName: symbol.name)
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

    func makeClosure(_ closure: ClosureExprSyntax, in env: Environment) -> ClosureValue {
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
        return ClosureValue(parameters: parameters, body: closure.statements, captured: env)
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
                    try target.write(box.value, self)
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
    private func bindGenericsFromClosureArguments(
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

    private func bindGenericReturnParameter(_ closure: ClosureValue, into env: Environment) {
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
                env.define(parameter.name, try resolveAnnotated(value, parameter: parameter))
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
                        env.define(parameter.name, slot.current)
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
                env.define(parameter.name, resolved)
                // `{ $item in … }` — the binding parameter also exposes its
                // wrapped value: `item` shares the binding's box, so reads
                // are live and writes propagate.
                if parameter.name.hasPrefix("$"), parameter.name.count > 1,
                   case .host(let any) = resolved, let stub = any as? BindingStub {
                    env.define(String(parameter.name.dropFirst()), sharing: stub.box)
                }
            } else if let defaultValue = parameter.defaultValue {
                env.define(parameter.name, try resolveAnnotated(
                    try evaluate(defaultValue, in: closure.captured), parameter: parameter))
            } else if let node {
                throw error(node, "missing argument for parameter '\(parameter.name)'")
            } else {
                throw RuntimeError(message: "missing argument for parameter '\(parameter.name)'")
            }
        }
        return writeBacks
    }

    // MARK: - Operators & assignment

    /// Assignment RHS carries the TARGET property's declared type as the
    /// ambient hint (`statuses = try await client.get()` — return-position
    /// generics bind at the call site, exactly like `let x: [Status] = …`).
    /// Only self-rooted targets are inspected: their annotation is knowable
    /// without evaluating anything.
    private func assignmentAnnotationHint(_ target: ExprSyntax, in env: Environment) -> String? {
        var propertyName: String?
        if let ref = target.as(DeclReferenceExprSyntax.self) {
            propertyName = ref.baseName.text
        } else if let member = target.as(MemberAccessExprSyntax.self),
                  member.base == nil
                    || member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            propertyName = member.declName.baseName.text
        }
        guard let propertyName,
              case .instance(let instance)? = env.lookup("self") else { return nil }
        return instance.symbol.storedProperty(named: propertyName)?.typeAnnotation?.trimmedDescription
    }

    func evaluateInfix(_ infix: InfixOperatorExprSyntax, in env: Environment) throws -> RuntimeValue {
        if infix.operator.is(AssignmentExprSyntax.self) {
            let hint = assignmentAnnotationHint(infix.leftOperand, in: env)
            let value = try withExpectedAnnotation(hint) { try evaluate(infix.rightOperand, in: env) }
            if infix.leftOperand.is(DiscardAssignmentExprSyntax.self) {
                _ = value // `_ = expr` — evaluate for effect, discard
                return .void
            }
            // Tuple destructuring assignment: `(self.first, self.second,
            // self.third) = (first, second, third)` writes element-wise.
            if let tuple = infix.leftOperand.as(TupleExprSyntax.self), tuple.elements.count > 1 {
                let values: [RuntimeValue]
                if let t = value.tupleValue {
                    values = t.values
                } else if let a = value.arrayValue {
                    values = a
                } else {
                    throw error(infix, "tuple assignment needs a tuple value")
                }
                guard values.count == tuple.elements.count else {
                    throw error(infix, "tuple assignment arity mismatch")
                }
                for (element, elementValue) in zip(tuple.elements, values) {
                    if element.expression.is(DiscardAssignmentExprSyntax.self) { continue }
                    let target = try resolveLValue(element.expression, in: env)
                    try relocating(infix) { try target.write(elementValue, self) }
                }
                return .void
            }
            let target = try resolveLValue(infix.leftOperand, in: env)
            try relocating(infix) { try target.write(value, self) }
            return .void
        }
        guard let binOp = infix.operator.as(BinaryOperatorExprSyntax.self) else {
            throw error(infix, "unsupported infix operator")
        }
        let op = binOp.operator.text

        switch op {
        case "&&":
            guard try expectBool(evaluate(infix.leftOperand, in: env), node: infix.leftOperand) else {
                return .native(false)
            }
            return .native(try expectBool(evaluate(infix.rightOperand, in: env), node: infix.rightOperand))
        case "||":
            if try expectBool(evaluate(infix.leftOperand, in: env), node: infix.leftOperand) {
                return .native(true)
            }
            return .native(try expectBool(evaluate(infix.rightOperand, in: env), node: infix.rightOperand))
        case "??":
            let lhs = try evaluate(infix.leftOperand, in: env)
            return lhs.isNil ? try evaluate(infix.rightOperand, in: env) : lhs
        case "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=":
            let target = try resolveLValue(infix.leftOperand, in: env)
            let rhs = try evaluate(infix.rightOperand, in: env)
            let current = try target.read(self)
            do {
                let combined = try relocating(infix) {
                    try Builtins.binary(String(op.dropLast()), current, rhs)
                }
                try target.write(combined, self)
            } catch let builtinError as RuntimeError where !builtinError.fatal {
                // USER-DECLARED operator functions: the whole compound form
                // first (`func +=(lhs: inout [Int: Movie], rhs: [Movie])` —
                // the MovieSwiftUI reducer genre), then a declared combining
                // form of the base operator.
                if case .closure(let fn)? = globals.lookup(op) {
                    let slot = InoutSlot(box: nil, target: target, current: current)
                    _ = try callClosure(fn, arguments: [.native(slot), rhs])
                    return .void
                }
                if case .closure(let fn)? = globals.lookup(String(op.dropLast())) {
                    try target.write(try callClosure(fn, arguments: [current, rhs]), self)
                    return .void
                }
                throw builtinError
            }
            return .void
        default:
            var lhs = try evaluate(infix.leftOperand, in: env)
            var rhs = try evaluate(infix.rightOperand, in: env)
            if op == "~=" {
                return .native(try matchRuntimePattern(lhs, subject: rhs, env: env, node: infix))
            }
            // Pure numeric pairs skip the marker/registry machinery below —
            // all of it is a no-op for concrete Int/Double operands.
            if let fast = try relocating(infix, { try Builtins.fastNumericBinary(op, lhs, rhs) }) {
                return fast
            }
            // `dragOffset == .zero` / `40 + .statusColumnsSpacing` — an
            // unresolved implicit member adopts the other operand's host
            // type before combining (static constants in user extensions
            // resolve to their real values). Call-shaped markers
            // (.init(…) elementwise arithmetic) only adopt for equality.
            let allowCalls = op == "==" || op == "!="
            lhs = try adoptHostType(of: rhs, for: lhs, allowCalls: allowCalls)
            rhs = try adoptHostType(of: lhs, for: rhs, allowCalls: allowCalls)
            // A USER-DECLARED `static func ==` on an interpreted type WINS
            // over structural equality — Loadable ignores its cancelBag in
            // its own ==, while payload-wise comparison would not (the
            // clean-architecture LoadableTests genre). `!=` negates it.
            if op == "==" || op == "!=",
               let viaDeclared = try equalsViaDeclaredOperator(lhs, rhs, node: Syntax(infix)) {
                return .bool(op == "==" ? viaDeclared : !viaDeclared)
            }
            // Host-typed operators the core can't know (`Text("a") + Text("b")`).
            if let registry, let combined = registry.combineValues(op, lhs, rhs) {
                return combined
            }
            do {
                return try relocating(infix) { try Builtins.binary(op, lhs, rhs) }
            } catch let builtinError as RuntimeError where !builtinError.fatal {
                if let viaDeclared = try declaredOperatorValue(op, lhs, rhs) {
                    return viaDeclared
                }
                // User-defined infix operators (`|>` pipe-forward, `~=`
                // overloads) — top-level operator functions.
                if case .closure(let closure)? = globals.lookup(op) {
                    return try callWithArguments(
                        closure,
                        args: CallArguments(arguments: [
                            .init(label: nil, value: lhs), .init(label: nil, value: rhs),
                        ]),
                        node: nil)
                }
                // Ecosystem operators from EXTERNAL modules: `|>` is
                // pipe-forward everywhere it exists (Overture/Point-Free);
                // `>>>`/`<<<` are function composition.
                if op == "|>" {
                    return try invoke(rhs, with: CallArguments(arguments: [
                        .init(label: nil, value: lhs),
                    ]), node: infix)
                }
                if op == "<|" {
                    return try invoke(lhs, with: CallArguments(arguments: [
                        .init(label: nil, value: rhs),
                    ]), node: infix)
                }
                if op == ">>>" || op == "<<<" || op == ">=>" {
                    // `>=>` is Point-Free's Kleisli composition — headlessly
                    // the monadic layer absorbs, so it composes like `>>>`.
                    let first = op == "<<<" ? rhs : lhs
                    let second = op == "<<<" ? lhs : rhs
                    let capturedNode = infix
                    return .hostFunction(HostFunction(name: op) { [weak self] args, _ in
                        guard let self else { throw RuntimeError(message: "interpreter gone") }
                        let x = args.positional(0) ?? .void
                        let mid = try self.invoke(first, with: CallArguments(arguments: [
                            .init(label: nil, value: x),
                        ]), node: capturedNode)
                        return try self.invoke(second, with: CallArguments(arguments: [
                            .init(label: nil, value: mid),
                        ]), node: capturedNode)
                    })
                }
                throw builtinError
            }
        }
    }

    private func adoptHostType(of other: RuntimeValue, for value: RuntimeValue, allowCalls: Bool = true) throws -> RuntimeValue {
        let unresolved: Bool
        switch value {
        case .implicitMember:
            unresolved = true
        case .host(let any):
            unresolved = allowCalls && (any is ImplicitMemberCall || any is ChainedImplicitCall)
        default:
            unresolved = false
        }
        guard unresolved, case .host(let otherAny) = other else { return value }
        // Our CGFloat/TimeInterval model IS Double — statics declared on
        // either name apply to Double operands.
        var candidates = [String(describing: type(of: otherAny))]
        if otherAny is Double { candidates += ["CGFloat", "TimeInterval"] }
        for typeName in candidates {
            let resolved = try resolveAnnotated(value, typeName: typeName)
            let stillUnresolved: Bool
            switch resolved {
            case .implicitMember: stillUnresolved = true
            case .nilValue: stillUnresolved = true // a nil never beats the marker
            case .host(let any):
                stillUnresolved = any is ImplicitMemberCall || any is ChainedImplicitCall
            default: stillUnresolved = false
            }
            if !stillUnresolved { return resolved }
        }
        return value
    }

    indirect enum LValue {
        case box(Box)
        case instanceProperty(Instance, String)
        case hostProperty(Any, String)
        case element(LValue, Int)
        case dictElement(DictValue, RuntimeValue)
        /// `trigger.0 = …` / `pair.label = …` — writes mutate the tuple and
        /// re-write the base, so state boxes still notify.
        case tupleElement(LValue, Int)
        /// `matrix[index] = block` — user subscript get/set.
        case instanceSubscript(Instance, CallArguments)
        /// `size.width = 300` — value-type member write-through: mutate a
        /// copy via the registry, re-write the base (state boxes notify).
        case hostValueMember(LValue, String)
        /// `ChatClient.shared = …` — static stored properties (including
        /// host-type extension statics) write to the symbol's static cache.
        case staticProperty(StructSymbol, String)
        /// `values[i] = UInt8(x)` — Data byte write-through: mutate a copy,
        /// re-write the base (value semantics).
        case dataElement(LValue, Int)

        /// The element type of an `[X]`-annotated instance property, if known.
        func annotatedElementType() -> String? {
            guard case .instanceProperty(let instance, let name) = self,
                  let annotation = instance.symbol.storedProperty(named: name)?.typeAnnotation else {
                return nil
            }
            let text = annotation.trimmedDescription.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("["), text.hasSuffix("]"), !text.contains(":") else { return nil }
            return String(text.dropFirst().dropLast())
        }

        func read(_ interpreter: Interpreter) throws -> RuntimeValue {
            switch self {
            case .box(let box):
                return try interpreter.force(box)
            case .instanceProperty(let instance, let name):
                if let box = instance.box(for: name) { return box.value }
                if let computed = instance.symbol.computedProperties[name] {
                    return try interpreter.evaluateComputed(computed, selfValue: .instance(instance), name: name)
                }
                if let superName = instance.symbol.superclassName,
                   !interpreter.isInterpretedType(superName) {
                    return .native(ChainedImplicitCall(
                        base: .implicitMember(superName), member: name, arguments: CallArguments()))
                }
                throw EvalMessage(text: "'\(instance.symbol.name)' has no property '\(name)'")
            case .hostProperty(let any, let name):
                if let stub = any as? BindingStub, name == "wrappedValue" {
                    return stub.box.value
                }
                if let value = interpreter.registry?.hostMember(name, on: any) { return value }
                if any is InertCallable || any is ImplicitMemberCall || any is ChainedImplicitCall {
                    // Mutating an unknown stub member (`store.products += …`)
                    // reads an unknowable chain — the write absorbs.
                    return .native(ChainedImplicitCall(
                        base: .native(any), member: name, arguments: CallArguments()))
                }
                throw EvalMessage(text: "no readable member '\(name)' on \(type(of: any))")
            case .element(let base, let index):
                guard let array = try base.read(interpreter).arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                return array[index]
            case .dictElement(let dict, let key):
                return try dict.lookup(key)
            case .tupleElement(let base, let index):
                guard let tuple = try base.read(interpreter).tupleValue,
                      tuple.values.indices.contains(index) else {
                    throw EvalMessage(text: "tuple element \(index) out of range")
                }
                return tuple.values[index]
            case .instanceSubscript(let instance, let args):
                return try interpreter.callUserSubscriptGetter(on: instance, with: args)
            case .staticProperty(let symbol, let name):
                return try interpreter.staticMember(name, of: symbol) ?? .nilValue
            case .dataElement(let base, let index):
                guard case .host(let any) = try base.read(interpreter), let bytes = any as? Data,
                      index >= 0, index < bytes.count else {
                    throw EvalMessage(text: "Data index \(index) out of range")
                }
                return .native(Int(bytes[bytes.index(bytes.startIndex, offsetBy: index)]))
            case .hostValueMember(let base, let name):
                let baseValue = try base.read(interpreter)
                guard case .host(let any) = baseValue,
                      let member = interpreter.registry?.hostMember(name, on: any) else {
                    throw EvalMessage(text: "no readable member '\(name)'")
                }
                return member
            }
        }

        func write(_ value: RuntimeValue, _ interpreter: Interpreter) throws {
            switch self {
            case .box(let box):
                box.value = value
            case .instanceProperty(let instance, let name):
                if Interpreter.traceStateCells,
                   name == (ProcessInfo.processInfo.environment["INTERP_TRACE_PROP"] ?? "statusesState") {
                    Swift.print("   ✍ \(instance.symbol.name)(\(UInt(bitPattern: ObjectIdentifier(instance).hashValue) % 100000)).\(name) = \(value.stringified.prefix(50))")
                }
                // Assigning a $binding into an @Binding property shares the
                // parent's box instead of copying the stub (custom inits).
                if case .host(let any) = value, let stub = any as? BindingStub,
                   instance.symbol.storedProperty(named: name)?.wrapper == .binding {
                    instance.properties[name] = stub.box
                    return
                }
                if let box = instance.box(for: name) {
                    // Plain assignment adopts the property's annotation
                    // (`self.amount = .random(in:)`, `self.date = .now`).
                    let property = instance.symbol.storedProperty(named: name)
                    // `_fetcher = .init(initialValue: vm)` — the property-
                    // wrapper BACKING spelling: the box takes the WRAPPED
                    // seed, not the `.init` marker (unwrapped BEFORE the
                    // annotation resolves, or a concrete annotation would
                    // eat the marker through its own constructor).
                    var incoming = value
                    if let property,
                       [.state, .stateObject, .observedObject, .binding].contains(property.wrapper),
                       case .host(let any) = incoming,
                       let call = any as? ImplicitMemberCall, call.name == "init",
                       let seed = call.arguments.labeled("initialValue")
                           ?? call.arguments.labeled("wrappedValue")
                           ?? call.arguments.labeled("projectedValue") {
                        incoming = seed
                    }
                    let resolved = try interpreter.resolveAnnotated(
                        incoming, annotation: property?.typeAnnotation
                    )
                    let observerKey = Interpreter.ObserverKey(
                        instance: ObjectIdentifier(instance), property: name)
                    let observed = (property?.willSetBody != nil || property?.didSetBody != nil)
                        && !interpreter.activePropertyObservers.contains(observerKey)
                        && !interpreter.initializingInstances.contains(ObjectIdentifier(instance))
                    guard observed, let property else {
                        box.value = resolved
                        return
                    }
                    // willSet(newValue) → write → didSet(oldValue), never
                    // re-entrant on the same property (compiled semantics;
                    // initialization bypasses this funnel entirely).
                    interpreter.activePropertyObservers.insert(observerKey)
                    defer { interpreter.activePropertyObservers.remove(observerKey) }
                    let oldValue = box.value
                    if let willSet = property.willSetBody {
                        let env = interpreter.selfEnvironment(.instance(instance))
                        env.define(property.willSetParameter, resolved)
                        _ = try interpreter.executeBlock(willSet, in: env)
                    }
                    box.value = resolved
                    if let didSet = property.didSetBody {
                        let env = interpreter.selfEnvironment(.instance(instance))
                        env.define(property.didSetParameter, oldValue)
                        _ = try interpreter.executeBlock(didSet, in: env)
                    }
                    return
                }
                if let computed = instance.symbol.computedProperties[name] {
                    guard let setter = computed.setter else {
                        if interpreter.assumesCompiledImports {
                            // A get-only assignment can't compile natively —
                            // the setter lives somewhere the merge didn't
                            // capture: the write drops (artifact doctrine).
                            return
                        }
                        throw EvalMessage(text: "cannot assign to get-only property '\(name)'")
                    }
                    let env = interpreter.selfEnvironment(.instance(instance))
                    env.define(setter.parameterName, value)
                    _ = try interpreter.executeBlock(setter.body, in: env)
                    return
                }
                if let superName = instance.symbol.superclassName,
                   !interpreter.isInterpretedType(superName) {
                    // Inherited HOST-superclass properties (NSPanel.title):
                    // writes create the box, later reads see the value.
                    instance.properties[name] = Box(value)
                    return
                }
                throw EvalMessage(text: "'\(instance.symbol.name)' has no property '\(name)'")
            case .hostProperty(let any, let name):
                if let stub = any as? BindingStub, name == "wrappedValue" {
                    // Extension methods on Binding write through the box —
                    // onChange fires the set-closure of computed bindings.
                    stub.box.value = value
                    return
                }
                guard interpreter.registry?.hostSetMember(name, on: any, to: value) == true else {
                    throw EvalMessage(text: "cannot assign to '\(name)' on \(type(of: any))")
                }
            case .element(let base, let index):
                // Read-modify-write through the base lvalue, so element writes
                // propagate box/publisher notifications all the way up.
                guard var array = try base.read(interpreter).arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                array[index] = value
                try base.write(.native(array), interpreter)
            case .dictElement(let dict, let key):
                try dict.update(key, to: value)
            case .tupleElement(let base, let index):
                guard let tuple = try base.read(interpreter).tupleValue,
                      tuple.values.indices.contains(index) else {
                    throw EvalMessage(text: "tuple element \(index) out of range")
                }
                tuple.values[index] = value
                // Re-write the base so state boxes notify.
                try base.write(.native(tuple), interpreter)
            case .instanceSubscript(let instance, let args):
                try interpreter.callUserSubscriptSetter(on: instance, with: args, newValue: value)
            case .staticProperty(let symbol, let name):
                symbol.staticCache[name] = value
            case .dataElement(let base, let index):
                guard case .host(let any) = try base.read(interpreter), var bytes = any as? Data,
                      index >= 0, index < bytes.count, let byte = value.intValue else {
                    throw EvalMessage(text: "Data byte write out of range")
                }
                bytes[bytes.index(bytes.startIndex, offsetBy: index)] = UInt8(truncatingIfNeeded: byte)
                try base.write(.native(bytes), interpreter)
            case .hostValueMember(let base, let name):
                let baseValue = try base.read(interpreter)
                guard case .host(let any) = baseValue,
                      let mutated = interpreter.registry?.hostMutatedCopy(
                        settingMember: name, on: any, to: value) else {
                    throw EvalMessage(text: "cannot assign to '\(name)' on \(baseValue.stringified)")
                }
                try base.write(.native(mutated), interpreter)
            }
        }
    }

    /// Equality THROUGH a user-declared `static func ==` when one applies —
    /// scalars dispatch directly; ARRAYS of such values compare elementwise
    /// through it (`sut == expect` over [Loadable<String>]). nil when no
    /// declared operator is involved; a declared body that trips an
    /// absorbed member falls back to structural (equality never throws).
    /// TYPE-declared operator functions — `static func < (lhs: Self,
    /// rhs: Self)` Comparable conformances and friends. Swift derives
    /// <=/>/>= from a declared `<`. nil when neither operand's type
    /// declares the operator.
    func declaredOperatorValue(
        _ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue
    ) throws -> RuntimeValue? {
        func operatorHome(_ value: RuntimeValue) -> (StructSymbol?, EnumSymbol?) {
            if case .instance(let instance) = value { return (instance.symbol, nil) }
            if case .enumCase(let caseValue) = value { return (nil, caseValue.symbol) }
            return (nil, nil)
        }
        func declared(_ name: String) -> (FunctionDeclSyntax, RuntimeValue)? {
            for operand in [lhs, rhs] {
                let (structSym, enumSym) = operatorHome(operand)
                if let method = structSym?.staticMethods[name]?.first {
                    return (method, .type(structSym!))
                }
                if let method = enumSym?.staticMethods[name]?.first {
                    return (method, .enumType(enumSym!))
                }
            }
            return nil
        }
        func runOperator(_ method: FunctionDeclSyntax, _ selfValue: RuntimeValue,
                         _ a: RuntimeValue, _ b: RuntimeValue) throws -> RuntimeValue {
            guard let body = method.body else {
                throw RuntimeError(message: "operator '\(op)' has no body")
            }
            let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(selfValue))
            return try callWithArguments(closure, args: CallArguments(arguments: [
                .init(label: nil, value: a), .init(label: nil, value: b),
            ]), node: nil)
        }
        if ["<", "<=", ">", ">="].contains(op) {
            if let (method, home) = declared(op) {
                return try runOperator(method, home, lhs, rhs)
            }
            if let (less, home) = declared("<") {
                switch op {
                case ">": return try runOperator(less, home, rhs, lhs)
                case "<=":
                    let greater = try runOperator(less, home, rhs, lhs)
                    return .native(!(greater.boolValue ?? false))
                default: // ">="
                    let lesser = try runOperator(less, home, lhs, rhs)
                    return .native(!(lesser.boolValue ?? false))
                }
            }
            return nil
        }
        if let (method, home) = declared(op) {
            return try runOperator(method, home, lhs, rhs)
        }
        return nil
    }

    /// Binary evaluation with full operator semantics for GATEWAYS
    /// (XCTAssert comparisons): declared `==`/`<` and derived forms win
    /// over structural/builtin comparison, exactly like infix expressions.
    public func evaluateBinary(
        _ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue
    ) throws -> RuntimeValue {
        if op == "==" || op == "!=",
           let viaDeclared = try equalsViaDeclaredOperator(lhs, rhs, node: nil) {
            return .bool(op == "==" ? viaDeclared : !viaDeclared)
        }
        do {
            return try Builtins.binary(op, lhs, rhs)
        } catch let builtinError as RuntimeError where !builtinError.fatal {
            if let viaDeclared = try declaredOperatorValue(op, lhs, rhs) { return viaDeclared }
            throw builtinError
        } catch let message as EvalMessage {
            if let viaDeclared = try declaredOperatorValue(op, lhs, rhs) { return viaDeclared }
            throw message
        }
    }

    private func equalsViaDeclaredOperator(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue, node: Syntax?
    ) throws -> Bool? {
        // A PAYLOAD-carrying marker beside an enum case resolves against
        // that case's symbol first (`values == [.isLoading(last: nil,
        // cancelBag: .test)]` — the literal rides annotation-less), so the
        // declared `==` compares two real cases.
        var lhs = lhs, rhs = rhs
        func looksLikeMarker(_ value: RuntimeValue) -> Bool {
            if case .implicitMember = value { return true }
            if case .host(let any) = value, any is ImplicitMemberCall { return true }
            return false
        }
        if case .enumCase(let l) = lhs, looksLikeMarker(rhs) {
            rhs = try resolveAnnotated(rhs, typeName: l.symbol.name)
        } else if case .enumCase(let r) = rhs, looksLikeMarker(lhs) {
            lhs = try resolveAnnotated(lhs, typeName: r.symbol.name)
        }
        if let declared = declaredEqualsOperator(lhs) ?? declaredEqualsOperator(rhs) {
            do {
                let result = try callWithArguments(
                    declared,
                    args: CallArguments(arguments: [
                        .init(label: nil, value: lhs), .init(label: nil, value: rhs),
                    ]),
                    node: node)
                if let b = result.boolValue { return b }
            } catch let opError as RuntimeError where !opError.fatal {
                // damus's Route == compares hashValues of absorbed members.
            }
            return nil
        }
        if let synthesized = try memberwiseStructEquality(lhs, rhs, node: node) {
            return synthesized
        }
        if let l = lhs.arrayValue, let r = rhs.arrayValue,
           let sample = l.first ?? r.first,
           declaredEqualsOperator(sample) != nil || isSynthesizableStruct(sample) {
            guard l.count == r.count else { return false }
            for (a, b) in zip(l, r) {
                let pair = try equalsViaDeclaredOperator(a, b, node: node)
                    ?? ((try? Builtins.areEqual(a, b)) ?? false)
                if !pair {
                    if Interpreter.traceStateCells {
                        FileHandle.standardError.write(Data("   ≠ \(a.stringified.prefix(90)) VS \(b.stringified.prefix(90))\n".utf8))
                    }
                    return false
                }
            }
            return true
        }
        return nil
    }

    private func isSynthesizableStruct(_ value: RuntimeValue) -> Bool {
        if case .instance(let instance) = value { return !instance.symbol.isClass }
        return false
    }

    /// Member-wise equality for struct instances — the interpreter's stand-in
    /// for Equatable synthesis. Classes keep identity semantics (native
    /// classes never get a synthesized `==`); each member comparison recurses
    /// through declared operators first, exactly like the compiled witness.
    private func memberwiseStructEquality(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue, node: Syntax?
    ) throws -> Bool? {
        guard case .instance(let l) = lhs, case .instance(let r) = rhs,
              !l.symbol.isClass, !r.symbol.isClass else { return nil }
        if l === r { return true }
        guard l.symbol === r.symbol || l.symbol.name == r.symbol.name else { return false }
        let pair = Interpreter.InstanceEqualityPair(
            lhs: ObjectIdentifier(l), rhs: ObjectIdentifier(r))
        guard !activeEqualityPairs.contains(pair) else { return true }
        activeEqualityPairs.insert(pair)
        defer { activeEqualityPairs.remove(pair) }
        let keys = Set(l.properties.keys).union(r.properties.keys)
        for key in keys {
            guard let leftBox = l.properties[key], let rightBox = r.properties[key] else {
                return false
            }
            let same = try equalsViaDeclaredOperator(leftBox.value, rightBox.value, node: node)
                ?? ((try? Builtins.areEqual(leftBox.value, rightBox.value)) ?? false)
            if !same { return false }
        }
        return true
    }

    /// The `static func ==` a value's own type (or its extensions)
    /// declares, as a callable — nil when the type doesn't customize
    /// equality or the declaration is already running (its body's inner
    /// `==` on payloads must fall through to structural equality).
    private func declaredEqualsOperator(_ value: RuntimeValue) -> ClosureValue? {
        let overloads: [FunctionDeclSyntax]?
        let selfValue: RuntimeValue
        let typeName: String
        switch value {
        case .enumCase(let caseValue):
            overloads = caseValue.symbol.staticMethods["=="]
            selfValue = .enumType(caseValue.symbol)
            typeName = caseValue.symbol.name
        case .instance(let instance):
            overloads = instance.symbol.staticMethods["=="]
            selfValue = .type(instance.symbol)
            typeName = instance.symbol.name
        default:
            return nil
        }
        if let method = overloads?.first(where: { !activeFunctionBodies.contains($0.id) }),
           let body = method.body {
            return makeFunctionClosure(method, body: body, captured: selfEnvironment(selfValue))
        }
        // Pre-protocol style: a TOP-LEVEL `func == (lhs: AppState, rhs:
        // AppState) -> Bool` satisfies Equatable too — match by the first
        // parameter's type name (last dotted component, extension-tolerant).
        let wanted = typeName.split(separator: ".").last.map(String.init) ?? typeName
        for decl in globalFunctionOverloads["=="] ?? [] where !activeFunctionBodies.contains(decl.id) {
            guard let body = decl.body,
                  let first = decl.signature.parameterClause.parameters.first else { continue }
            let paramType = first.type.trimmedDescription
            let head = paramType.split(separator: ".").last.map(String.init) ?? paramType
            if head == wanted {
                return makeFunctionClosure(decl, body: body, captured: globals)
            }
        }
        return nil
    }

    func resolveLValue(_ expr: ExprSyntax, in env: Environment) throws -> LValue {
        // `_ = sideEffect()` — a discard sink.
        if expr.is(DiscardAssignmentExprSyntax.self) {
            return .box(Box(.void))
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if Interpreter.traceStateCells, name == "statusesState" {
                var selfDesc = "none"
                if case .instance(let i)? = env.lookup("self") { selfDesc = i.symbol.name }
                Swift.print("   ⌥ lvalue statusesState envBox=\(env.box(for: name) != nil) self=\(selfDesc)")
            }
            // Real Swift scoping, write side: locals first, implicit-self
            // members second, globals LAST — a property named like a global
            // builtin (`log`, `min`) must not write into the builtin's box.
            if let box = env.box(for: name, before: globals) { return .box(box) }
            if case .instance(let instance)? = env.lookup("self") {
                let canonical = instance.symbol.canonicalPropertyName(name)
                if instance.box(for: canonical) != nil || instance.symbol.computedProperties[canonical] != nil {
                    return .instanceProperty(instance, canonical)
                }
                if let superName = instance.symbol.superclassName,
                   !isInterpretedType(superName) {
                    // Inherited host-superclass property (`title = …` in an
                    // NSPanel subclass) — the write absorbs into a box.
                    return .instanceProperty(instance, canonical)
                }
            }
            // Bare sibling statics inside static methods:
            // `static func show() { shared = … }`.
            if case .type(let symbol)? = env.lookup("self"),
               symbol.staticProperties[name] != nil
                || symbol.staticUninitialized.contains(name)
                || symbol.staticCache[name] != nil {
                return .staticProperty(symbol, name)
            }
            // Bare static COMPUTED setters under a type self
            // (`firstRunDate = Date()` inside a property-initializer
            // closure, the setter living in a private extension).
            if case .type(let symbol)? = env.lookup("self"),
               let computed = symbol.staticComputedProperties[name],
               let setter = computed.setter {
                let box = Box(.void)
                box.onChange = { [weak self] in
                    guard let self else { return }
                    let setterEnv = self.selfEnvironment(.type(symbol))
                    setterEnv.define(setter.parameterName, box.value)
                    _ = try? self.executeBlock(setter.body, in: setterEnv)
                }
                return .box(box)
            }
            // Enum namespaces hold mutable statics too (`storage.append(…)`
            // inside a static setter): writes land in the static cache.
            if case .enumType(let symbol)? = env.lookup("self"),
               symbol.staticProperties[name] != nil || symbol.staticCache[name] != nil {
                let box = Box((try? staticMember(name, of: symbol)) ?? .void)
                box.onChange = { symbol.staticCache[name] = box.value }
                return .box(box)
            }
            // Host-typed implicit self (extension-of-host-type bodies):
            // `wrappedValue = …` inside `extension Binding { func load }`
            // writes through the binding's box. Restricted to the binding's
            // OWN properties — other bare names must still reach globals
            // (an absorbing host self would swallow them).
            if case .host(let any)? = env.lookup("self"), any is BindingStub,
               name == "wrappedValue" || name == "projectedValue" {
                return .hostProperty(any, name)
            }
            // No local or member claimed the name — top-level globals last.
            if let box = globals.box(for: name) { return .box(box) }
            throw error(ref, "cannot assign to '\(name)'")
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            // `ChatClient.shared = …` — static stored properties, including
            // host-type extension statics. Locals shadow type names.
            if let baseRef = base.as(DeclReferenceExprSyntax.self),
               env.box(for: baseRef.baseName.text, before: globals) == nil {
                let typeName = baseRef.baseName.text
                let memberName = member.declName.baseName.text
                // `Self.useServer = …` inside a static body: Self IS the
                // enclosing type.
                var typeValue = globals.lookup(typeName)
                if typeName == "Self", let selfValue = env.lookup("self") {
                    typeValue = selfValue
                    // Instance contexts: Self IS the instance's type.
                    if case .instance(let instance) = selfValue {
                        typeValue = .type(instance.symbol)
                    } else if case .enumCase(let caseValue) = selfValue {
                        typeValue = .enumType(caseValue.symbol)
                    }
                }
                var staticSymbol: StructSymbol?
                if case .type(let symbol)? = typeValue {
                    staticSymbol = symbol
                } else if let hostSymbol = hostExtensionSymbols[typeName] {
                    staticSymbol = hostSymbol
                }
                if let symbol = staticSymbol,
                   symbol.staticProperties[memberName] != nil
                    || symbol.staticUninitialized.contains(memberName)
                    || symbol.staticCache[memberName] != nil {
                    return .staticProperty(symbol, memberName)
                }
                // Static COMPUTED setters (`static var useServer { get set }`
                // assigned via Self./TypeName.): a Box whose onChange runs
                // the setter — the computed-binding precedent.
                var setterRun: ((RuntimeValue) -> Void)?
                if let symbol = staticSymbol,
                   let computed = symbol.staticComputedProperties[memberName],
                   let setter = computed.setter {
                    setterRun = { [weak self] value in
                        guard let self else { return }
                        let env = self.selfEnvironment(.type(symbol))
                        env.define(setter.parameterName, value)
                        _ = try? self.executeBlock(setter.body, in: env)
                    }
                } else if case .enumType(let symbol)? = typeValue,
                          let computed = symbol.staticComputedProperties[memberName],
                          let setter = computed.setter {
                    setterRun = { [weak self] value in
                        guard let self else { return }
                        let env = self.selfEnvironment(.enumType(symbol))
                        env.define(setter.parameterName, value)
                        _ = try? self.executeBlock(setter.body, in: env)
                    }
                }
                if let setterRun {
                    let box = Box(.void)
                    box.onChange = { setterRun(box.value) }
                    return .box(box)
                }
            }
            let baseValue = try evaluate(base, in: env)
            if case .instance(let instance) = baseValue {
                return .instanceProperty(instance, instance.symbol.canonicalPropertyName(member.declName.baseName.text))
            }
            if case .host(let any) = baseValue {
                // `binding.wrappedValue = …` writes straight through the box.
                if let stub = any as? BindingStub, member.declName.baseName.text == "wrappedValue" {
                    return .box(stub.box)
                }
                if let tuple = any as? TupleValue {
                    let memberName = member.declName.baseName.text
                    let index = Int(memberName) ?? tuple.labels.firstIndex(of: memberName) ?? -1
                    if tuple.values.indices.contains(index), let baseLValue = try? resolveLValue(base, in: env) {
                        return .tupleElement(baseLValue, index)
                    }
                }
                if registry != nil {
                    // VALUE types (CGSize/CGPoint/CGRect…) write through a
                    // mutated copy so the base re-writes and notifies. Only
                    // structs with a readable same-named member route here;
                    // class-backed boxes keep hostProperty reference writes.
                    let memberName = member.declName.baseName.text
                    if !(type(of: any) is AnyClass),
                       registry?.hostMember(memberName, on: any) != nil,
                       let baseLValue = try? resolveLValue(base, in: env) {
                        return .hostValueMember(baseLValue, memberName)
                    }
                    // Host objects with settable members (formatter.dateFormat = …).
                    return .hostProperty(any, memberName)
                }
            }
            if case .implicitMember(let markerName) = baseValue {
                // Config writes on unresolved host statics are accepted and
                // ignored (the marker-write doctrine).
                return .hostProperty(
                    ImplicitMemberCall(name: markerName, arguments: CallArguments()),
                    member.declName.baseName.text)
            }
            if case .hostFunction(let fn) = baseValue {
                // `LaunchAtLogin.isEnabled = …` — external-package statics
                // resolve to constructor functions; writes are accepted.
                return .hostProperty(
                    ImplicitMemberCall(name: fn.name, arguments: CallArguments()),
                    member.declName.baseName.text)
            }
            if assumesCompiledImports, baseValue.isNil || {
                if case .void = baseValue { return true } else { return false }
            }() {
                // A nil/void base from absorbed chains (`sequencer.tracks[1]`
                // on a fresh store; a DI property nothing injected): the
                // write is accepted and ignored, the marker-write doctrine.
                return .hostProperty(
                    ImplicitMemberCall(name: "nil", arguments: CallArguments()),
                    member.declName.baseName.text)
            }
            throw error(member, "cannot assign to a member of \(baseValue.stringified)")
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            guard let indexExpr = subscriptCall.arguments.first?.expression else {
                throw error(subscriptCall, "missing subscript index")
            }
            let baseValue = try? evaluate(subscriptCall.calledExpression, in: env)
            if case .instance(let instance)? = baseValue, !instance.symbol.subscripts.isEmpty {
                let indexArgs = CallArguments(arguments: try subscriptCall.arguments.map {
                    .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
                })
                return .instanceSubscript(instance, indexArgs)
            }
            if let dict = baseValue?.dictValue {
                return .dictElement(dict, try evaluate(indexExpr, in: env))
            }
            // `element[keyPath: kp] = value` — keypath writes walk to the
            // last component's owner and assign the property.
            if subscriptCall.arguments.first?.label?.text == "keyPath" {
                let keyValue = try evaluate(indexExpr, in: env)
                if case .host(let any) = keyValue, let stub = any as? KeyPathStub,
                   let last = stub.components.last, last != "self" {
                    var owner = try evaluate(subscriptCall.calledExpression, in: env)
                    for component in stub.components.dropLast() where component != "self" {
                        owner = try accessMember(component, on: owner, node: subscriptCall, env: env)
                    }
                    if case .instance(let instance) = owner {
                        return .instanceProperty(instance, instance.symbol.canonicalPropertyName(last))
                    }
                }
                throw error(subscriptCall, "unsupported keyPath assignment target")
            }
            // Store WRITES remember (`Defaults[.previewWidth] = w`): the
            // key bag's declared default updates, so later reads round-trip
            // within the run — fresh-store bag semantics.
            if let keyBag = try storeKeyBag(base: baseValue, indexExpr: indexExpr, in: env) {
                let seed = registry?.hostMember("default", on: keyBag) ?? .void
                let box = Box(seed)
                box.onChange = { [weak self] in
                    _ = self?.registry?.hostSetMember("default", on: keyBag, to: box.value)
                }
                return .box(box)
            }
            // USER-DECLARED subscript setters (`appState[\\.route] = x` on
            // clean-architecture's Store): seed from the getter, write
            // through the setter — declared semantics beat element writes.
            if let owningBase = baseValue,
               let (symbol, selfValue) = userSubscriptOwner(for: owningBase),
               symbol.subscripts.contains(where: { $0.setter != nil }) {
                let indexArgs = CallArguments(arguments: try subscriptCall.arguments.map {
                    .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
                })
                let seed = (try? runUserSubscriptGetter(symbol, selfValue: selfValue, args: indexArgs)) ?? .void
                let box = Box(seed)
                box.onChange = { [weak self] in
                    guard let self else { return }
                    try? self.runUserSubscriptSetter(
                        symbol, selfValue: selfValue, args: indexArgs, newValue: box.value)
                }
                return .box(box)
            }
            let base = try resolveLValue(subscriptCall.calledExpression, in: env)
            let indexValue = try evaluate(indexExpr, in: env)
            guard let index = indexValue.intValue else {
                // KEYED assignment onto a DEFERRED store (`var routers:
                // [Tab: Router]` initialized in an init our synthesis
                // skipped): the dictionary auto-vivifies.
                let current = try base.read(self)
                let isVoid: Bool = { if case .void = current { return true } else { return false } }()
                let isMarker: Bool = {
                    if let payload = current.hostPayload {
                        return payload is InertCallable || payload is ChainedImplicitCall
                            || payload is ImplicitMemberCall
                    }
                    if case .implicitMember = current { return true }
                    if case .hostFunction = current { return true }
                    return false
                }()
                if current.isNil || isVoid || isMarker {
                    let dict = DictValue()
                    try base.write(.native(dict), self)
                    return .dictElement(dict, indexValue)
                }
                if let dict = current.dictValue {
                    return .dictElement(dict, indexValue)
                }
                throw error(subscriptCall, "subscript assignment requires an Int index")
            }
            if case .host(let any)? = baseValue, any is Data {
                return .dataElement(base, index) // byte write-through
            }
            return .element(base, index)
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return try resolveLValue(only.expression, in: env)
        }
        // `components.hour! += 1` — optionals ARE the value, so the
        // force-unwrap lvalue writes through the wrapped path.
        if let force = expr.as(ForceUnwrapExprSyntax.self) {
            return try resolveLValue(force.expression, in: env)
        }
        throw error(expr, "expression is not assignable")
    }

    // MARK: - Literals & helpers

    private func integerValue(of lit: IntegerLiteralExprSyntax) throws -> Int {
        let text = lit.literal.text.filter { $0 != "_" }
        let value: Int?
        if text.hasPrefix("0x") { value = Int(text.dropFirst(2), radix: 16) }
        else if text.hasPrefix("0b") { value = Int(text.dropFirst(2), radix: 2) }
        else if text.hasPrefix("0o") { value = Int(text.dropFirst(2), radix: 8) }
        else { value = Int(text) }
        guard let value else { throw error(lit, "invalid integer literal") }
        return value
    }

    func stringLiteral(_ lit: StringLiteralExprSyntax, in env: Environment) throws -> String {
        if let simple = lit.representedLiteralValue { return simple }
        var out = ""
        for segment in lit.segments {
            switch segment {
            case .stringSegment(let s):
                out += unescape(s.content.text)
            case .expressionSegment(let e):
                for labeled in e.expressions {
                    let value = try evaluate(labeled.expression, in: env)
                    // Unknowables read "" in string interpolation — the
                    // fresh-string doctrine; internal marker dumps must
                    // never reach rendered Text.
                    if case .host(let any) = value,
                       any is InertCallable || any is ChainedImplicitCall
                        || any is ImplicitMemberCall {
                        continue
                    }
                    if case .implicitMember = value { continue }
                    if case .hostFunction = value { continue }
                    out += value.stringified
                }
            }
        }
        return out
    }

    private func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\", let next = iterator.next() else {
                out.append(ch)
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"": out.append("\"")
            case "'": out.append("'")
            case "\\": out.append("\\")
            default:
                out.append(ch)
                out.append(next)
            }
        }
        return out
    }

    /// Library key-value stores with DECLARED key defaults (sindresorhus/
    /// Defaults): `Store[.key]` resolves `Store.Keys.key`'s bag, whose
    /// `default:` argument is the fresh-store value (reads) and updates on
    /// writes.
    private func storeKeyBag(base: RuntimeValue?, indexExpr: ExprSyntax, in env: Environment) throws -> Any? {
        guard let base else { return nil }
        guard case .implicitMember = try evaluate(indexExpr, in: env) else { return nil }
        return try storeKeyBag(base: base, index: try evaluate(indexExpr, in: env))
    }

    private func storeKeyBag(base: RuntimeValue, index: RuntimeValue) throws -> Any? {
        let storeTypeName: String? = {
            if case .host(let baseAny) = base, let marker = baseAny as? HostTypeMarker {
                return marker.name
            }
            if case .hostFunction(let fn) = base { return fn.name } // ctor catch-all
            if case .enumType(let symbol) = base { return symbol.name } // vendored store
            if case .type(let symbol) = base { return symbol.name }
            return nil
        }()
        guard let storeTypeName,
              case .implicitMember(let keyName) = index,
              let keysSymbol = hostExtensionSymbols["\(storeTypeName).Keys"],
              let keyValue = try staticMember(keyName, of: keysSymbol),
              case .host(let keyAny) = keyValue else { return nil }
        return keyAny
    }

    private func evaluateSubscript(_ call: SubscriptCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        let base = try evaluate(call.calledExpression, in: env)
        if base.isNil { return .nilValue }
        guard let indexExpr = call.arguments.first?.expression else {
            throw error(call, "missing subscript index")
        }
        let index = try evaluate(indexExpr, in: env)
        // EnvironmentValues getters: `self[Key.self]` reads the key type's
        // static defaultValue (pre-@Entry EnvironmentKey conformances).
        if case .host(let any) = base, any is EnvironmentValuesStub {
            if case .type(let keySymbol) = index {
                return try staticMember("defaultValue", of: keySymbol) ?? .nilValue
            }
            return .nilValue
        }
        if call.arguments.first?.label?.text == "keyPath" {
            // `element[keyPath: kp]` — apply the stub's components.
            if case .host(let any) = index, let stub = any as? KeyPathStub {
                return try applyKeyPath(stub, to: base)
            }
            return .nilValue // unknowable keypath: fresh read
        }
        if let array = base.arrayValue {
            if let i = index.intValue, array.indices.contains(i) {
                return array[i]
            }
            if let range = index.rangeValue {
                let bounds = try integerSlice(range, count: array.count, name: "array", node: call)
                return .native(Array(array[bounds]))
            }
            throw error(call, "array index out of range")
        }
        if let dict = base.dictValue {
            return try relocating(call) { try dict.lookup(index) }
        }
        if let range = base.rangeValue, let i = index.intValue {
            guard let materialized = range.integerValues() else {
                throw error(call, "only integer ranges can be indexed")
            }
            guard materialized.indices.contains(i) else { throw error(call, "range index out of range") }
            return materialized[i]
        }
        if case .host(let any) = base, let stub = any as? BindingStub, let i = index.intValue {
            // `$items[index]` — a write-through element binding.
            guard let element = stub.elementBinding(at: i) else {
                throw error(call, "binding index out of range")
            }
            return element
        }
        if let (symbol, selfValue) = userSubscriptOwner(for: base) {
            // User subscript getter: `matrix[index]` / `grid[x, y]` — and
            // host-extension subscripts (`appState[\\.permissions.push]`).
            let indexArgs = CallArguments(arguments: try call.arguments.map {
                .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
            })
            return try relocating(call) {
                try runUserSubscriptGetter(symbol, selfValue: selfValue, args: indexArgs)
            }
        }
        if case .host(let stringAny) = base, let string = stringAny as? String {
            // `text[range]` / `text[i]` with String.Index values.
            if let range = index.rangeValue {
                return .native(String(string[try stringSlice(range, in: string, node: call)]))
            }
            if case .host(let indexAny) = index,
               let position = indexAny as? String.Index,
               position >= string.startIndex, position < string.endIndex {
                    return .native(String(string[position]))
            }
        }
        // Library key-value stores with DECLARED defaults (sindresorhus/
        // Defaults: `Defaults[.windowSize]` with `Defaults.Keys.windowSize =
        // Key("…", default: NSSize(…))`): a fresh store answers the key's
        // declared default — the @Default-wrapper doctrine at subscript level.
        if let keyBag = try storeKeyBag(base: base, index: index),
           let declared = registry?.hostMember("default", on: keyBag)
               ?? registry?.hostMember("defaultValue", on: keyBag) {
            return declared
        }
        if case .host(let any) = base,
           case .hostFunction(let subscripting)? = registry?.hostMember("subscript", on: any) {
            // Host subscripts (AttributedString[range] styling proxies).
            let args = CallArguments(arguments: [.init(label: nil, value: index)])
            return try relocating(call) { try subscripting.invoke(args, self) }
        }
        if case .host(let dataAny) = base, let bytes = dataAny as? Data {
            // Byte access and slices (bech32 decoders index raw buffers).
            if let i = index.intValue {
                guard i >= 0, i < bytes.count else {
                    throw error(call, "Data index \(i) out of range")
                }
                return .native(Int(bytes[bytes.index(bytes.startIndex, offsetBy: i)]))
            }
            if let range = index.rangeValue {
                let bounds = try integerSlice(range, count: bytes.count, name: "Data", node: call)
                let start = bytes.index(bytes.startIndex, offsetBy: bounds.lowerBound)
                let end = bytes.index(bytes.startIndex, offsetBy: bounds.upperBound)
                return .native(Data(bytes[start..<end]))
            }
        }
        // A TYPE base that isn't a declared-default store: in compiled
        // mode the subscript is a static-subscript surface the merge can't
        // model (a vendored Defaults shim shadowed by a design-token
        // namespace) — absorbs.
        if assumesCompiledImports {
            if case .enumType = base {
                return .native(ChainedImplicitCall(
                    base: base, member: "subscript",
                    arguments: CallArguments(arguments: [.init(label: nil, value: index)])))
            }
            if case .type = base {
                return .native(ChainedImplicitCall(
                    base: base, member: "subscript",
                    arguments: CallArguments(arguments: [.init(label: nil, value: index)])))
            }
        }
        // Subscripting an unknowable host collection (Bundle.main
        // .infoDictionary?[…]) reads nil — the empty fresh store; the
        // caller's ?? fallback applies, as on a device without that key.
        if case .host(let any) = base,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            return .nilValue
        }
        if case .implicitMember = base { return .nilValue }
        if case .hostFunction = base { return .nilValue }
        throw error(call, "subscripting is only supported on arrays and dictionaries, got \(base.stringified)")
    }

    private func integerSlice(
        _ range: RuntimeRangeValue,
        count: Int,
        name: String,
        node: some SyntaxProtocol
    ) throws -> Range<Int> {
        let lower = range.lowerBound?.intValue ?? 0
        var upper = range.upperBound?.intValue ?? count
        if range.includesUpperBound, range.upperBound != nil {
            guard upper < count else { throw error(node, "\(name) slice out of bounds") }
            upper += 1
        }
        guard lower >= 0, upper <= count, lower <= upper else {
            throw error(node, "\(name) slice out of bounds")
        }
        return lower..<upper
    }

    private func stringSlice(
        _ range: RuntimeRangeValue,
        in string: String,
        node: some SyntaxProtocol
    ) throws -> Range<String.Index> {
        func index(_ value: RuntimeValue?, fallback: String.Index) throws -> String.Index {
            guard let value else { return fallback }
            if let offset = value.intValue {
                guard offset >= 0, offset <= string.count else {
                    throw error(node, "string slice out of bounds")
                }
                return string.index(string.startIndex, offsetBy: offset)
            }
            if case .host(let any) = value, let index = any as? String.Index {
                return index
            }
            throw error(node, "string slice needs Int or String.Index bounds")
        }

        let lower = try index(range.lowerBound, fallback: string.startIndex)
        var upper = try index(range.upperBound, fallback: string.endIndex)
        if range.includesUpperBound, range.upperBound != nil {
            guard upper < string.endIndex else { throw error(node, "string slice out of bounds") }
            upper = string.index(after: upper)
        }
        guard lower >= string.startIndex, upper <= string.endIndex, lower <= upper else {
            throw error(node, "string slice out of bounds")
        }
        return lower..<upper
    }

    func expectBool(_ value: RuntimeValue, node: some SyntaxProtocol) throws -> Bool {
        guard let b = value.boolValue else {
            // Hosted-object truths (`context.canEvaluatePolicy(…)`,
            // `engine.isRunning`) read their fresh-state value — FALSE for
            // everything except `isEmpty` chains, which read TRUE (the
            // fresh store's collection is empty, agreeing with for-in).
            if let fresh = Builtins.unknowableBool(value) { return fresh }
            // A VOID Bool can't compile natively — an absorbed-environment
            // artifact reading fresh false.
            if case .void = value { return false }
            // Nil from optional chains through stubs reads false too.
            if value.isNil { return false }
            throw error(node, "expected a Bool, got \(value.stringified)")
        }
        return b
    }

    /// Run a Builtins call, upgrading its unlocated `EvalMessage` to a located error.
    @discardableResult
    func relocating<T>(_ node: some SyntaxProtocol, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let message as EvalMessage {
            throw error(node, message.text)
        }
    }
}
