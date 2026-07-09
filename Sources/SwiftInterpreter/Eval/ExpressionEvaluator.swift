import Foundation
import SwiftSyntax

/// Expression evaluation: the big dispatch over folded `ExprSyntax`.
extension Interpreter {
    func evaluate(_ expr: ExprSyntax, in env: Environment) throws -> RuntimeValue {
        try tick(expr)

        if let lit = expr.as(IntegerLiteralExprSyntax.self) {
            return .native(try integerValue(of: lit))
        }
        if let lit = expr.as(FloatLiteralExprSyntax.self) {
            guard let d = Double(lit.literal.text.filter { $0 != "_" }) else {
                throw error(lit, "invalid float literal")
            }
            return .native(d)
        }
        if let lit = expr.as(BooleanLiteralExprSyntax.self) {
            return .native(lit.literal.text == "true")
        }
        if expr.is(NilLiteralExprSyntax.self) {
            return .nilValue
        }
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            return .native(try stringLiteral(lit, in: env))
        }
        if let array = expr.as(ArrayExprSyntax.self) {
            return .native(try array.elements.map { try evaluate($0.expression, in: env) })
        }
        if let dict = expr.as(DictionaryExprSyntax.self) {
            let value = DictValue()
            if case .elements(let elements) = dict.content {
                for element in elements {
                    try relocating(element) {
                        try value.update(try evaluate(element.key, in: env), to: try evaluate(element.value, in: env))
                    }
                }
            }
            return .native(value)
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return try resolveIdentifier(ref.baseName.text, in: env, node: ref)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else {
                return .implicitMember(member.declName.baseName.text)
            }
            let baseValue = try evaluate(base, in: env)
            return try accessMember(member.declName.baseName.text, on: baseValue, node: member, env: env)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return try evaluateCall(call, in: env)
        }
        if let closure = expr.as(ClosureExprSyntax.self) {
            return .closure(makeClosure(closure, in: env))
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return try evaluateInfix(infix, in: env)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            if prefix.operator.text == "..<" || prefix.operator.text == "..." {
                let bound = try evaluate(prefix.expression, in: env)
                return .native(PartialRangeValue(upper: bound, closed: prefix.operator.text == "..."))
            }
            if prefix.operator.text == "/",
               globals.lookup(prefix.operator.text) == nil {
                // The CasePaths case-path operator: `/AppAction.milestone`.
                // The operand is a case REFERENCE (not a value) — keep it
                // textual; consumers are framework machinery that absorbs.
                return .native(CasePathMarker(path: prefix.expression.trimmedDescription))
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
        }
        if let postfix = expr.as(PostfixOperatorExprSyntax.self) {
            if postfix.operator.text == "..." {
                let bound = try evaluate(postfix.expression, in: env)
                return .native(PartialRangeValue(lower: bound))
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
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            let condition = try expectBool(evaluate(ternary.condition, in: env), node: ternary.condition)
            return try evaluate(condition ? ternary.thenExpression : ternary.elseExpression, in: env)
        }
        if let tuple = expr.as(TupleExprSyntax.self) {
            if tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil {
                return try evaluate(only.expression, in: env)
            }
            let labels = tuple.elements.map { $0.label?.text }
            let values = try tuple.elements.map { try evaluate($0.expression, in: env) }
            return .native(TupleValue(labels: labels, values: values))
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            return try evaluateSubscript(subscriptCall, in: env)
        }
        if let forceUnwrap = expr.as(ForceUnwrapExprSyntax.self) {
            let value = try evaluate(forceUnwrap.expression, in: env)
            guard !value.isNil else {
                throw error(forceUnwrap, "unexpectedly found nil while force-unwrapping")
            }
            return value
        }
        if let chaining = expr.as(OptionalChainingExprSyntax.self) {
            // Member/call/subscript on nil propagates nil (see accessMember/invoke).
            return try evaluate(chaining.expression, in: env)
        }
        if let tryExpr = expr.as(TryExprSyntax.self) {
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
        }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) {
            // Synchronous stand-in: async work evaluates inline (documented).
            return try evaluate(awaitExpr.expression, in: env)
        }
        if let keyPath = expr.as(KeyPathExprSyntax.self) {
            let components = keyPath.components.map {
                $0.trimmedDescription.hasPrefix(".")
                    ? String($0.trimmedDescription.dropFirst())
                    : $0.trimmedDescription
            }
            return .native(KeyPathStub(components: components))
        }
        if expr.is(SuperExprSyntax.self) {
            guard case .instance(let instance)? = env.lookup("self") else {
                throw error(expr, "'super' can only be used inside a class body")
            }
            return .native(SuperReference(instance: instance))
        }
        if let inout_ = expr.as(InOutExprSyntax.self) {
            // `&cancellables` — reference semantics make inout moot here.
            return try evaluate(inout_.expression, in: env)
        }
        if let macro = expr.as(MacroExpansionExprSyntax.self) {
            // `#selector(...)`, `#Predicate {...}` — inert marker values;
            // consumers (sendAction, flattened queries) ignore them.
            return .native(HostTypeMarker(name: "#\(macro.macroName.text)"))
        }
        if let asExpr = expr.as(AsExprSyntax.self) {
            // Dynamic casts: give the target type a chance to resolve markers,
            // bridge numerics, and otherwise pass the value through
            // (optimistic `as?` — documented divergence).
            let value = try evaluate(asExpr.expression, in: env)
            if asExpr.questionOrExclamationMark?.text == "?", value.isNil {
                return .nilValue
            }
            var typeName = asExpr.type.trimmedDescription
            if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }
            switch typeName {
            case "Double", "CGFloat", "TimeInterval":
                if let d = value.doubleValue { return .native(d) }
            case "Int":
                if let d = value.doubleValue { return .native(Int(d)) }
            default:
                break
            }
            return try resolveAnnotated(value, typeName: typeName)
        }
        if let ifExpr = expr.as(IfExprSyntax.self) {
            if case .normal(let value) = try executeIf(ifExpr, in: env) { return value }
            throw error(ifExpr, "control flow can't escape an if-expression")
        }
        if let switchExpr = expr.as(SwitchExprSyntax.self) {
            if case .normal(let value) = try executeSwitch(switchExpr, in: env) { return value }
            throw error(switchExpr, "control flow can't escape a switch-expression")
        }
        if let postfixIf = expr.as(PostfixIfConfigExprSyntax.self) {
            // `view \n #if os(iOS) \n .modifier() \n #endif` — apply the
            // active clause's postfix chain to the base (inactive: base).
            let baseValue = try postfixIf.base.map { try evaluate($0, in: env) } ?? .void
            guard let clause = activeIfConfigClause(postfixIf.config),
                  case .postfixExpression(let postfix)? = clause.elements else {
                return baseValue
            }
            let child = Environment(parent: env)
            child.define("__postfixBase", baseValue)
            return try evaluate(graftPostfixBase(postfix, name: "__postfixBase"), in: child)
        }
        if let generic = expr.as(GenericSpecializationExprSyntax.self) {
            // Type arguments are annotations we don't check —
            // `Binding<Int?>(get:set:)` evaluates as `Binding(get:set:)`.
            return try evaluate(generic.expression, in: env)
        }
        if expr.is(SequenceExprSyntax.self) {
            throw error(expr, "internal error: unfolded operator sequence")
        }
        throw error(expr, "unsupported expression (\(expr.kind))")
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
        if case .native(let any) = box.value, let computed = any as? ComputedGlobal {
            // Global computed var: evaluate fresh on every read.
            let result = try executeBlock(computed.accessor, in: Environment(parent: globals))
            switch result {
            case .normal(let value), .returnValue(let value):
                return try resolveAnnotated(value, annotation: computed.annotation)
            default:
                return .void
            }
        }
        guard case .native(let any) = box.value, let lazy = any as? LazyGlobal else {
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

    func resolveIdentifier(_ name: String, in env: Environment, node: some SyntaxProtocol) throws -> RuntimeValue {
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
                if case .native(let any) = local, any is BindingStub {
                    return local
                }
            }
            guard case .instance(let instance)? = env.lookup("self") else {
                throw error(node, "'\(name)' can only be used inside a View body")
            }
            // `$searchText` on a @Published property (inside the model) is
            // the Combine publisher projection — an inert pipeline.
            if let property = instance.symbol.storedProperty(named: propertyName),
               property.wrapper == .published {
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
                    if case .native(let any)? = boxValue,
                       any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                        return boxValue ?? .nilValue
                    }
                    if case .implicitMember? = boxValue { return boxValue ?? .nilValue }
                    if case .hostFunction? = boxValue { return boxValue ?? .nilValue }
                    throw error(node, "'\(name)' has no model instance assigned")
                }
                return .native(ModelProjection(model: model))
            }
            guard let box = instance.projectedBox(for: propertyName) else {
                throw error(node, "'\(name)' requires an @State or @Binding property named '\(propertyName)'")
            }
            return .native(BindingStub(box: box))
        }
        if let selfValue = env.lookup("self"),
           let value = try selfMember(name, on: selfValue) {
            return value
        }
        if let box = globals.box(for: name) { return try force(box) }
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
        if let ctor = registry?.constructor(named: name) {
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
        if let selfValue = env.lookup("self"),
           let modifier = registry?.modifier(named: name),
           let target = modifierTarget(for: selfValue) {
            return .hostFunction(HostFunction(name: name) { args, ctx in
                try modifier.apply(target, args, ctx)
            })
        }
        // Unresolved snake_case identifiers are C imports (sqlite3_open,
        // ndb_builder — the merge holds all the app's OWN Swift): inert
        // absorbing functions, values chain per the fresh-state doctrine.
        if Self.cStdlibNames.contains(name)
            || (name.contains("_") && name.first?.isLowercase == true)
            || (name.hasPrefix("_") && name.dropFirst().first?.isLowercase == true)
            || assumesCompiledImports {
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(ChainedImplicitCall(
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
        case .native(let any):
            // Bare `count`/`firstIndex(...)` inside a host-type extension body
            // is implicit self on the native value.
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
        let name = instance.symbol.canonicalPropertyName(rawName)
        if name == "objectWillChange", instance.symbol.isClass {
            let signal = instance.changeSignal
            return .native(ObjectWillChangePublisher(fire: { signal.fire() }))
        }
        if let box = instance.box(for: name),
           case .native(let any) = box.value, let seed = any as? LazyMemberSeed {
            // Force the lazy member now, with self bound.
            let value = try resolveAnnotated(
                try evaluate(seed.initializer, in: selfEnvironment(.instance(instance))),
                annotation: seed.annotation)
            box.value = value
            return value
        }
        // A type's OWN nested types shadow same-named globals inside its
        // body (each IceCubes package declares its own `enum Constants`).
        if let nested = instance.symbol.nestedTypes[name] { return nested }
        if let box = instance.box(for: name) { return box.value }
        // Interpreted-superclass members dispatch with self unchanged
        // (inheritance: methods and computed properties walk the chain).
        var parentName = instance.symbol.superclassName
        while let superName = parentName {
            guard case .type(let parent)? = globals.lookup(superName) else { break }
            if let overloads = parent.methods[name], let method = overloads.first,
               let body = method.body {
                return .closure(makeFunctionClosure(
                    method, body: body, captured: selfEnvironment(.instance(instance))))
            }
            if let computed = parent.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
            parentName = parent.superclassName
        }
        if let method = instance.symbol.methods[name]?.first {
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.instance(instance))))
        }
        if let computed = instance.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
        }
        if instance.symbol.conformsToView,
           let value = try hostExtensionMember(name, candidates: ["View"], selfValue: .instance(instance)) {
            return value
        }
        // Protocol-extension defaults: `extension GameLogic { func start() … }`
        // serves conformers that don't define the member themselves.
        for conformance in instance.symbol.conformances {
            guard let proto = hostExtensionSymbols[conformance] else { continue }
            if let method = proto.methods[name]?.first, let body = method.body {
                return .closure(makeFunctionClosure(
                    method, body: body, captured: selfEnvironment(.instance(instance))))
            }
            if let computed = proto.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
        }
        return nil
    }

    /// Interpreted extension-of-host-type members (`extension View { … }`).
    func hostExtensionMember(_ name: String, candidates: [String], selfValue: RuntimeValue) throws -> RuntimeValue? {
        for typeName in candidates {
            guard let symbol = hostExtensionSymbols[typeName] else { continue }
            if let method = symbol.methods[name]?.first, let body = method.body {
                return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(selfValue)))
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
        if any is [RuntimeValue] {
            // `extension Array` and sugar-typed `extension [Item]` both apply.
            names.append("Array")
            names.append(contentsOf: hostExtensionSymbols.keys.filter { $0.hasPrefix("[") })
        }
        // Protocol umbrellas: `extension Collection { var isNotEmpty }`
        // applies to every conforming native (twostraws idiom).
        if any is [RuntimeValue] || any is String || any is DictValue
            || any is Range<Int> || any is ClosedRange<Double> {
            names.append("Collection")
            names.append("Sequence")
        }
        if any is [RuntimeValue] {
            names.append("RandomAccessCollection")
            names.append("MutableCollection")
            names.append("BidirectionalCollection")
        }
        if any is String { names.append("StringProtocol") }
        if any is Int { names.append("BinaryInteger"); names.append("Numeric") }
        if any is Double { names.append("FloatingPoint"); names.append("BinaryFloatingPoint") }
        return names
    }

    private func enumCaseMember(_ name: String, on value: EnumCaseValue) throws -> RuntimeValue? {
        if name == "rawValue" { return value.rawValue }
        if let method = value.symbol.methods[name]?.first {
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumCase(value))))
        }
        if let computed = value.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .enumCase(value), name: name)
        }
        return nil
    }

    /// Runs the best-matching user subscript getter (picked by arity).
    func callUserSubscriptGetter(on instance: Instance, with args: CallArguments) throws -> RuntimeValue {
        guard let member = instance.symbol.subscripts.first(where: { $0.parameters.count == args.arguments.count })
            ?? instance.symbol.subscripts.first else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no subscript")
        }
        let env = selfEnvironment(.instance(instance))
        let closure = ClosureValue(parameters: member.parameters, body: member.getter, captured: env)
        return try callWithArguments(closure, args: args, node: nil)
    }

    /// Runs the user subscript setter with `newValue` and the index bound.
    func callUserSubscriptSetter(on instance: Instance, with args: CallArguments, newValue: RuntimeValue) throws {
        guard let member = instance.symbol.subscripts.first(where: { $0.parameters.count == args.arguments.count })
            ?? instance.symbol.subscripts.first else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no subscript")
        }
        guard let setter = member.setter else {
            throw RuntimeError(message: "subscript on '\(instance.symbol.name)' is get-only")
        }
        let env = selfEnvironment(.instance(instance))
        for (parameter, argument) in zip(member.parameters, args.arguments) {
            env.define(parameter.name, try resolveAnnotated(argument.value, annotation: parameter.typeAnnotation))
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
                    guard let chosen = self.chooseInitializerStrict(
                        from: instance.symbol.initializers, for: args) else {
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
            if let value = try instanceMember(name, on: instance) { return value }
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
            if name == "allCases" {
                let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                    RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
                }
                return .native(all)
            }
            if let value = try staticMember(name, of: symbol) {
                return value
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

        case .native(let any):
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
                default:
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
                    if case .native(let inner) = stub.box.value,
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
            if let typeName = registry?.hostTypeName(of: any),
               let value = try hostExtensionMember(name, candidates: [typeName], selfValue: baseValue) {
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
                guard let box = projection.model.box(for: name) else {
                    throw error(node, "'$\(projection.model.symbol.name)' has no stored property '\(name)'")
                }
                return .native(BindingStub(box: box))
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
            throw error(node, "unsupported member '\(name)' on \(type(of: any))")

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
        if let method = symbol.staticMethods[name]?.first, let body = method.body {
            // Static context: `self`/`Self` and bare sibling statics resolve.
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.type(symbol))))
        }
        if symbol.staticUninitialized.contains(name) { return .nilValue }
        return nil
    }

    func staticMember(_ name: String, of symbol: EnumSymbol) throws -> RuntimeValue? {
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
        if let method = symbol.staticMethods[name]?.first, let body = method.body {
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumType(symbol))))
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

    func evaluateCall(_ call: FunctionCallExprSyntax, in env: Environment) throws -> RuntimeValue {
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
               let overloads = instance.symbol.methods[name], overloads.count > 1 {
                let args = try collectArguments(of: call, in: env)
                if let method = chooseFunction(from: overloads, for: args) ?? overloads.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.instance(instance)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            let callee = try accessMember(name, on: baseValue, node: member, env: env)
            let args = try collectArguments(of: call, in: env)
            do {
                return try invoke(callee, with: args, node: call)
            } catch let bindingError as RuntimeError
                where !bindingError.fatal
                    && (bindingError.message.hasPrefix("missing argument")
                        || bindingError.message.hasSuffix("is not callable")) {
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
            if case .instance(let instance)? = env.lookup("self"),
               let overloads = instance.symbol.methods[name], overloads.count > 1 {
                let args = try collectArguments(of: call, in: env)
                if let method = chooseFunction(from: overloads, for: args) ?? overloads.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.instance(instance)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            if case .type(let symbol)? = env.lookup("self"),
               let overloads = symbol.staticMethods[name], overloads.count > 1 {
                let args = try collectArguments(of: call, in: env)
                if let method = chooseFunction(from: overloads, for: args) ?? overloads.first,
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
        // Bool.toggle() — ubiquitous in SwiftUI code (`show.toggle()`); writes
        // through the lvalue so @State/@Published notification fires.
        if name == "toggle",
           let target = try? resolveLValue(base, in: env),
           let current = try target.read(self).boolValue {
            _ = try collectArguments(of: call, in: env) // evaluate (empty) args for side effects
            try relocating(call) { try target.write(.native(!current), self) }
            return .void
        }

        // Data mutations write through the lvalue (value semantics):
        // `data.append(other)` / `data.append(byte)`.
        if name == "append",
           let target = try? resolveLValue(base, in: env),
           case .native(let existingAny) = try target.read(self),
           var bytes = existingAny as? Data {
            let args = try collectArguments(of: call, in: env)
            guard let value = args.positional(0) else {
                throw error(call, "append needs a value")
            }
            if case .native(let addAny) = value, let more = addAny as? Data {
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
                  case .native(let idxAny)? = args.labeled("at"),
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
                guard let value = args.positional(0), let index = args.labeled("at")?.intValue,
                      index >= 0, index <= array.count else {
                    throw error(call, "insert needs a value and a valid at: index")
                }
                array.insert(try resolved(value), at: index)
            case "remove":
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
                    do { return try Builtins.binary("<", a, b).boolValue == true }
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
            let array = baseValue.arrayValue ?? baseValue.rangeValue.map { range in range.map { RuntimeValue.native($0) } }
            if let array {
                let args = try collectArguments(of: call, in: env)
                if let closure = args.closure(labeled: "where") ?? args.unlabeledClosures.first {
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

    func invoke(_ callee: RuntimeValue, with args: CallArguments, node: some SyntaxProtocol) throws -> RuntimeValue {
        switch callee {
        case .nilValue:
            return .nilValue // optional chaining through a nil method
        case .type(let symbol):
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
                    throw bindingError
                }
            }
        case .closure(let closure):
            return try callWithArguments(closure, args: args, node: Syntax(node))
        case .hostFunction(let function):
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
            let constructible = symbol.initializers.filter { !Interpreter.isCodableInit($0) }
            if constructible.isEmpty, args.arguments.count == 1,
               let raw = args.positional(0) {
                if let matched = symbol.cases
                    .first(where: { (try? Builtins.areEqual($0.rawValue, raw)) == true }) {
                    return .enumCase(EnumCaseValue(symbol: symbol, name: matched.name))
                }
            }
            if !constructible.isEmpty {
                let chosen = chooseInitializer(from: constructible, for: args)
                guard let body = chosen.body else {
                    throw error(node, "init of '\(symbol.name)' has no body")
                }
                let env = Environment(parent: globals)
                env.define("self", .void)
                let parameters = chosen.signature.parameterClause.parameters.map { param in
                    ClosureValue.Parameter(
                        name: (param.secondName ?? param.firstName).text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                        label: param.firstName.text == "_" ? nil : param.firstName.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                        defaultValue: param.defaultValue?.value,
                        typeAnnotation: param.type
                    )
                }
                let closure = ClosureValue(parameters: parameters, body: body.statements, captured: env)
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
        case .native(let any) where any is ChainedImplicitCall:
            let chained = any as! ChainedImplicitCall
            return .native(ChainedImplicitCall(base: chained.base, member: chained.member, arguments: args))
        case .native(let any) where any is HostTypeMarker:
            let marker = any as! HostTypeMarker
            throw error(node, "'\(marker.name)' has no interpreter constructor — only its static members (like \(marker.name).something) are supported")
        case .native(let any) where any is InertCallable:
            return callee // inert-chainable host stub call
        default:
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
                parameters = clause.parameters.map { .init(name: ($0.secondName ?? $0.firstName).text) }
            }
        }
        return ClosureValue(parameters: parameters, body: closure.statements, captured: env)
    }

    func callWithArguments(_ closure: ClosureValue, args: CallArguments, node: Syntax?) throws -> RuntimeValue {
        callDepth += 1
        defer { callDepth -= 1 }
        guard callDepth < callDepthLimit else {
            if let node {
                let located = error(node, "call depth exceeded (possible infinite recursion)")
                throw RuntimeError(
                    message: located.message, line: located.line, column: located.column, fatal: true)
            }
            throw RuntimeError(message: "call depth exceeded (possible infinite recursion)", fatal: true)
        }
        let env = Environment(parent: closure.captured)
        try bindParameters(of: closure, to: args, into: env, node: node)
        if closure.isBuilder {
            let items = try collectBuilderViews(closure.body, in: env)
            // `[X]`-returning builders (custom @resultBuilders' buildBlock)
            // collect into an ARRAY; view-typed ones group as views.
            if closure.returnType?.trimmedDescription.hasPrefix("[") == true {
                return .native(items)
            }
            return try groupViews(items)
        }
        let result = try executeBlock(closure.body, in: env)
        switch result {
        case .normal(let value), .returnValue(let value):
            return try resolveAnnotated(value, annotation: closure.returnType)
        case .breakLoop, .continueLoop:
            throw RuntimeError(message: "break/continue escaped a function body")
        }
    }

    /// Label-aware binding: labeled arguments match parameter labels, omitted
    /// defaulted parameters (including in the middle) fall back to their
    /// defaults, positional arguments fill unlabeled parameters in order, and
    /// the unlabeled trailing closure binds to the LAST unbound parameter.
    /// No-parameter closures get `$0`, `$1`, … shorthand bindings.
    func bindParameters(of closure: ClosureValue, to args: CallArguments, into env: Environment, node: Syntax?) throws {
        if closure.parameters.isEmpty {
            for (index, argument) in args.arguments.enumerated() {
                env.define("$\(index)", argument.value)
            }
            return
        }

        // `{ index, char in … }` over enumerated() — one tuple argument
        // splats across multiple parameters.
        if closure.parameters.count > 1, args.arguments.count == 1,
           let tuple = args.arguments[0].value.tupleValue,
           tuple.values.count == closure.parameters.count {
            for (parameter, value) in zip(closure.parameters, tuple.values) {
                env.define(parameter.name, try resolveAnnotated(value, annotation: parameter.typeAnnotation))
            }
            return
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
        // The unlabeled trailing closure binds to the last unbound parameter.
        for trailing in unlabeledTrailing.reversed() {
            if let index = bound.indices.last(where: { bound[$0] == nil }) {
                bound[index] = trailing
            }
        }

        for (index, parameter) in closure.parameters.enumerated() {
            if let value = bound[index] {
                var resolved = try resolveAnnotated(value, annotation: parameter.typeAnnotation)
                // The result-builder transform: a closure bound to a
                // @…Builder parameter collects its block's items when
                // called instead of returning the last expression.
                if parameter.isBuilderAttributed, case .closure(let c) = resolved, !c.isBuilder {
                    resolved = .closure(ClosureValue(
                        parameters: c.parameters, body: c.body, captured: c.captured,
                        isBuilder: true,
                        returnType: ClosureValue.Parameter.functionReturnType(of: parameter.typeAnnotation) ?? c.returnType
                    ))
                }
                env.define(parameter.name, resolved)
                // `{ $item in … }` — the binding parameter also exposes its
                // wrapped value: `item` shares the binding's box, so reads
                // are live and writes propagate.
                if parameter.name.hasPrefix("$"), parameter.name.count > 1,
                   case .native(let any) = resolved, let stub = any as? BindingStub {
                    env.define(String(parameter.name.dropFirst()), sharing: stub.box)
                }
            } else if let defaultValue = parameter.defaultValue {
                env.define(parameter.name, try resolveAnnotated(
                    try evaluate(defaultValue, in: closure.captured),
                    annotation: parameter.typeAnnotation
                ))
            } else if let node {
                throw error(node, "missing argument for parameter '\(parameter.name)'")
            } else {
                throw RuntimeError(message: "missing argument for parameter '\(parameter.name)'")
            }
        }
    }

    // MARK: - Operators & assignment

    func evaluateInfix(_ infix: InfixOperatorExprSyntax, in env: Environment) throws -> RuntimeValue {
        if infix.operator.is(AssignmentExprSyntax.self) {
            let value = try evaluate(infix.rightOperand, in: env)
            if infix.leftOperand.is(DiscardAssignmentExprSyntax.self) {
                _ = value // `_ = expr` — evaluate for effect, discard
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
            try relocating(infix) {
                let combined = try Builtins.binary(String(op.dropLast()), try target.read(self), rhs)
                try target.write(combined, self)
            }
            return .void
        default:
            var lhs = try evaluate(infix.leftOperand, in: env)
            var rhs = try evaluate(infix.rightOperand, in: env)
            // `dragOffset == .zero` / `40 + .statusColumnsSpacing` — an
            // unresolved implicit member adopts the other operand's host
            // type before combining (static constants in user extensions
            // resolve to their real values). Call-shaped markers
            // (.init(…) elementwise arithmetic) only adopt for equality.
            let allowCalls = op == "==" || op == "!="
            lhs = try adoptHostType(of: rhs, for: lhs, allowCalls: allowCalls)
            rhs = try adoptHostType(of: lhs, for: rhs, allowCalls: allowCalls)
            // Host-typed operators the core can't know (`Text("a") + Text("b")`).
            if let registry, let combined = registry.combineValues(op, lhs, rhs) {
                return combined
            }
            do {
                return try relocating(infix) { try Builtins.binary(op, lhs, rhs) }
            } catch let builtinError as RuntimeError where !builtinError.fatal {
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
                if op == ">>>" || op == "<<<" {
                    let first = op == ">>>" ? lhs : rhs
                    let second = op == ">>>" ? rhs : lhs
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
        case .native(let any):
            unresolved = allowCalls && (any is ImplicitMemberCall || any is ChainedImplicitCall)
        default:
            unresolved = false
        }
        guard unresolved, case .native(let otherAny) = other else { return value }
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
            case .native(let any):
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
                guard case .native(let any) = try base.read(interpreter), let bytes = any as? Data,
                      index >= 0, index < bytes.count else {
                    throw EvalMessage(text: "Data index \(index) out of range")
                }
                return .native(Int(bytes[bytes.index(bytes.startIndex, offsetBy: index)]))
            case .hostValueMember(let base, let name):
                let baseValue = try base.read(interpreter)
                guard case .native(let any) = baseValue,
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
                // Assigning a $binding into an @Binding property shares the
                // parent's box instead of copying the stub (custom inits).
                if case .native(let any) = value, let stub = any as? BindingStub,
                   instance.symbol.storedProperty(named: name)?.wrapper == .binding {
                    instance.properties[name] = stub.box
                    return
                }
                if let box = instance.box(for: name) {
                    // Plain assignment adopts the property's annotation
                    // (`self.amount = .random(in:)`, `self.date = .now`).
                    box.value = try interpreter.resolveAnnotated(
                        value, annotation: instance.symbol.storedProperty(named: name)?.typeAnnotation
                    )
                    return
                }
                if let computed = instance.symbol.computedProperties[name] {
                    guard let setter = computed.setter else {
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
                guard case .native(let any) = try base.read(interpreter), var bytes = any as? Data,
                      index >= 0, index < bytes.count, let byte = value.intValue else {
                    throw EvalMessage(text: "Data byte write out of range")
                }
                bytes[bytes.index(bytes.startIndex, offsetBy: index)] = UInt8(truncatingIfNeeded: byte)
                try base.write(.native(bytes), interpreter)
            case .hostValueMember(let base, let name):
                let baseValue = try base.read(interpreter)
                guard case .native(let any) = baseValue,
                      let mutated = interpreter.registry?.hostMutatedCopy(
                        settingMember: name, on: any, to: value) else {
                    throw EvalMessage(text: "cannot assign to '\(name)' on \(baseValue.stringified)")
                }
                try base.write(.native(mutated), interpreter)
            }
        }
    }

    func resolveLValue(_ expr: ExprSyntax, in env: Environment) throws -> LValue {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if let box = env.box(for: name) { return .box(box) }
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
            throw error(ref, "cannot assign to '\(name)'")
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            // `ChatClient.shared = …` — static stored properties, including
            // host-type extension statics. Locals shadow type names.
            if let baseRef = base.as(DeclReferenceExprSyntax.self),
               env.box(for: baseRef.baseName.text, before: globals) == nil {
                let typeName = baseRef.baseName.text
                let memberName = member.declName.baseName.text
                var staticSymbol: StructSymbol?
                if case .type(let symbol)? = globals.lookup(typeName) {
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
            }
            let baseValue = try evaluate(base, in: env)
            if case .instance(let instance) = baseValue {
                return .instanceProperty(instance, instance.symbol.canonicalPropertyName(member.declName.baseName.text))
            }
            if case .native(let any) = baseValue {
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
            let base = try resolveLValue(subscriptCall.calledExpression, in: env)
            guard let index = try evaluate(indexExpr, in: env).intValue else {
                throw error(subscriptCall, "subscript assignment requires an Int index")
            }
            if case .native(let any)? = baseValue, any is Data {
                return .dataElement(base, index) // byte write-through
            }
            return .element(base, index)
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return try resolveLValue(only.expression, in: env)
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
                    out += try evaluate(labeled.expression, in: env).stringified
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

    private func evaluateSubscript(_ call: SubscriptCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        let base = try evaluate(call.calledExpression, in: env)
        if base.isNil { return .nilValue }
        guard let indexExpr = call.arguments.first?.expression else {
            throw error(call, "missing subscript index")
        }
        let index = try evaluate(indexExpr, in: env)
        if let array = base.arrayValue {
            guard let i = index.intValue, array.indices.contains(i) else {
                throw error(call, "array index out of range")
            }
            return array[i]
        }
        if let dict = base.dictValue {
            return try relocating(call) { try dict.lookup(index) }
        }
        if let range = base.rangeValue, let i = index.intValue {
            let materialized = Array(range)
            guard materialized.indices.contains(i) else { throw error(call, "range index out of range") }
            return .native(materialized[i])
        }
        if case .native(let any) = base, let stub = any as? BindingStub, let i = index.intValue {
            // `$items[index]` — a write-through element binding.
            guard let element = stub.elementBinding(at: i) else {
                throw error(call, "binding index out of range")
            }
            return element
        }
        if case .instance(let instance) = base, !instance.symbol.subscripts.isEmpty {
            // User subscript getter: `matrix[index]` / `grid[x, y]`.
            let indexArgs = CallArguments(arguments: try call.arguments.map {
                .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
            })
            return try relocating(call) {
                try callUserSubscriptGetter(on: instance, with: indexArgs)
            }
        }
        if case .native(let stringAny) = base, let string = stringAny as? String,
           case .native(let indexAny) = index {
            // `text[range]` / `text[i]` with String.Index values.
            if let indexRange = indexAny as? Range<String.Index>,
               indexRange.lowerBound >= string.startIndex, indexRange.upperBound <= string.endIndex {
                return .native(String(string[indexRange]))
            }
            if let position = indexAny as? String.Index, position >= string.startIndex,
               position < string.endIndex {
                return .native(String(string[position]))
            }
        }
        if case .native(let any) = base,
           case .hostFunction(let subscripting)? = registry?.hostMember("subscript", on: any) {
            // Host subscripts (AttributedString[range] styling proxies).
            let args = CallArguments(arguments: [.init(label: nil, value: index)])
            return try relocating(call) { try subscripting.invoke(args, self) }
        }
        if case .native(let partAny) = index, let part = partAny as? PartialRangeValue {
            // Partial-range slices: str[..<pos], bytes[pos...], array[..<n].
            if case .native(let strAny) = base, let string = strAny as? String {
                let lower = (part.lower.flatMap { if case .native(let a) = $0 { return a as? String.Index } else { return nil } }) ?? string.startIndex
                var upper = (part.upper.flatMap { if case .native(let a) = $0 { return a as? String.Index } else { return nil } }) ?? string.endIndex
                if let lowInt = part.lower?.intValue { return .native(String(string.dropFirst(lowInt))) }
                if let upInt = part.upper?.intValue {
                    let count = part.closed ? upInt + 1 : upInt
                    return .native(String(string.prefix(count)))
                }
                if part.closed, upper < string.endIndex { upper = string.index(after: upper) }
                guard lower >= string.startIndex, upper <= string.endIndex, lower <= upper else {
                    throw error(call, "string slice out of bounds")
                }
                return .native(String(string[lower..<upper]))
            }
            if case .native(let dataAny) = base, let bytes = dataAny as? Data {
                let lower = part.lower?.intValue ?? 0
                var upper = part.upper?.intValue ?? bytes.count
                if part.closed, part.upper != nil { upper += 1 }
                guard lower >= 0, upper <= bytes.count, lower <= upper else {
                    throw error(call, "Data slice out of bounds")
                }
                let start = bytes.index(bytes.startIndex, offsetBy: lower)
                let end = bytes.index(bytes.startIndex, offsetBy: upper)
                return .native(Data(bytes[start..<end]))
            }
            if let array = base.arrayValue {
                let lower = part.lower?.intValue ?? 0
                var upper = part.upper?.intValue ?? array.count
                if part.closed, part.upper != nil { upper += 1 }
                guard lower >= 0, upper <= array.count, lower <= upper else {
                    throw error(call, "array slice out of bounds")
                }
                return .native(Array(array[lower..<upper]))
            }
        }
        if case .native(let dataAny) = base, let bytes = dataAny as? Data {
            // Byte access and slices (bech32 decoders index raw buffers).
            if let i = index.intValue {
                guard i >= 0, i < bytes.count else {
                    throw error(call, "Data index \(i) out of range")
                }
                return .native(Int(bytes[bytes.index(bytes.startIndex, offsetBy: i)]))
            }
            if let range = index.rangeValue {
                guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
                    throw error(call, "Data range out of bounds")
                }
                let start = bytes.index(bytes.startIndex, offsetBy: range.lowerBound)
                let end = bytes.index(bytes.startIndex, offsetBy: range.upperBound)
                return .native(Data(bytes[start..<end]))
            }
        }
        // Subscripting an unknowable host collection (Bundle.main
        // .infoDictionary?[…]) reads nil — the empty fresh store; the
        // caller's ?? fallback applies, as on a device without that key.
        if case .native(let any) = base,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            return .nilValue
        }
        if case .implicitMember = base { return .nilValue }
        if case .hostFunction = base { return .nilValue }
        throw error(call, "subscripting is only supported on arrays and dictionaries, got \(base.stringified)")
    }

    func expectBool(_ value: RuntimeValue, node: some SyntaxProtocol) throws -> Bool {
        guard let b = value.boolValue else {
            // Hosted-object truths (`context.canEvaluatePolicy(…)`,
            // `engine.isRunning`) read FALSE — fresh system state: no
            // biometrics, nothing running headlessly.
            if case .native(let any) = value,
               any is InertCallable || any is ImplicitMemberCall || any is ChainedImplicitCall {
                return false
            }
            // A bound host-member FUNCTION in Bool position is equally an
            // artifact of stub reads — fresh-state false.
            if case .hostFunction = value { return false }
            // Nil from optional chains through stubs reads false too.
            if value.isNil { return false }
            // Bare `.member` markers (unresolved host statics) read false.
            if case .implicitMember = value { return false }
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
