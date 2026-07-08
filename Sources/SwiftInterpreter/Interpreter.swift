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
    /// Interpreted `extension View { … }` / `extension String { … }` members,
    /// keyed by the extended host type's name.
    var hostExtensionSymbols: [String: StructSymbol] = [:]

    var locationConverter: SourceLocationConverter?
    var steps = 0
    /// Guards against `while true {}` freezing the UI: evaluation is main-actor.
    let stepBudget = 100_000

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
        let folded = OperatorTable.standardOperators.foldAll(tree) { operatorErrors.append($0) }
        if let first = operatorErrors.first {
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
        for item in file.statements {
            if case .decl(let decl) = item.item,
               decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self)
                || decl.is(FunctionDeclSyntax.self)
                || decl.is(EnumDeclSyntax.self) || decl.is(ExtensionDeclSyntax.self) {
                continue // already collected
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

    /// Custom `init`s run with `self` bound to a defaults-initialized instance;
    /// otherwise default + memberwise initialization applies. `$binding`
    /// arguments for `@Binding` properties share the parent's Box.
    public func instantiate(_ symbol: StructSymbol, with args: CallArguments, node: Syntax? = nil) throws -> RuntimeValue {
        let instance = Instance(symbol: symbol)
        let notifying = Set(symbol.notifyingPropertyNames)
        for property in symbol.storedProperties {
            var value = RuntimeValue.void
            if let initializer = property.initializer {
                value = try resolveAnnotated(try evaluate(initializer, in: globals), annotation: property.typeAnnotation)
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
            for argument in args.arguments {
                if let label = argument.label {
                    guard let property = symbol.storedProperty(named: label),
                          let box = instance.box(for: label) else {
                        let message = "argument '\(label)' doesn't match a stored property of '\(symbol.name)'"
                        if let node { throw error(node, message) }
                        throw RuntimeError(message: message)
                    }
                    assigned.insert(label)
                    if property.wrapper == .binding,
                       case .native(let any) = argument.value, let stub = any as? BindingStub {
                        instance.properties[label] = stub.box
                    } else {
                        box.value = try resolveAnnotated(argument.value, annotation: property.typeAnnotation)
                    }
                } else if let closure = argument.value.closureValue {
                    // Trailing closure → last unassigned closure-shaped stored
                    // property; @ViewBuilder properties store the BUILT view
                    // (matching Swift's synthesized memberwise + builder init).
                    guard let property = symbol.storedProperties.last(where: {
                        !assigned.contains($0.name) && $0.acceptsTrailingClosure
                    }), let box = instance.box(for: property.name) else {
                        let message = "trailing closure doesn't match a closure property of '\(symbol.name)'"
                        if let node { throw error(node, message) }
                        throw RuntimeError(message: message)
                    }
                    assigned.insert(property.name)
                    let functionTyped = property.typeAnnotation?.trimmedDescription.contains("->") ?? false
                    if property.isBuilderClosure && !functionTyped {
                        // `@ViewBuilder var content: Content` — build now.
                        box.value = try groupViews(try callBuilderClosure(closure, arguments: []))
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
            let chosen = chooseInitializer(from: symbol.initializers, for: args)
            guard let body = chosen.body else {
                throw RuntimeError(message: "init of '\(symbol.name)' has no body")
            }
            let parameters = chosen.signature.parameterClause.parameters.map { param in
                ClosureValue.Parameter(
                    name: (param.secondName ?? param.firstName).text,
                    defaultValue: param.defaultValue?.value,
                    typeAnnotation: param.type
                )
            }
            let closure = ClosureValue(
                parameters: parameters,
                body: body.statements,
                captured: selfEnvironment(.instance(instance))
            )
            _ = try callWithArguments(closure, args: args, node: node)
        }
        return .instance(instance)
    }

    private func chooseInitializer(from initializers: [InitializerDeclSyntax], for args: CallArguments) -> InitializerDeclSyntax {
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

    /// Fill `@EnvironmentObject` properties from ambient models (keyed by type
    /// name). The SwiftUI bridge reads the models off the real Environment;
    /// headless harnesses thread them down the trace tree.
    public func injectEnvironmentObjects(into instance: Instance, models: [String: Instance]) throws {
        for property in instance.symbol.storedProperties where property.wrapper == .environmentObject {
            let typeName = property.typeAnnotation?.trimmedDescription ?? ""
            guard let model = models[typeName] else {
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
            guard case .environment(let key) = property.wrapper,
                  let value = values[key] else { continue }
            instance.box(for: property.name)?.value = value
        }
    }

    /// The struct to render when the program doesn't end in an explicit view
    /// expression: `ContentView` if present, then `Main`, then the first
    /// View-conforming struct in declaration order.
    public func rootViewSymbol() -> StructSymbol? {
        let candidates = structSymbols.filter(\.conformsToView)
        return candidates.first { $0.name == "ContentView" }
            ?? candidates.first { $0.name == "Main" }
            ?? candidates.first
    }

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
               let staticValue = try staticMember(name, properties: symbol.staticProperties, methods: symbol.staticMethods, cache: &symbol.staticCache) {
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
            return .nilValue
        }
        define("Double") { args, _ in
            guard let value = args.positional(0) else { return .nilValue }
            if let d = value.doubleValue { return .native(d) }
            if let s = value.stringValue { return Double(s).map { RuntimeValue.native($0) } ?? .nilValue }
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
            guard let value = args.positional(0) else { return .native([RuntimeValue]()) }
            if let range = value.rangeValue { return .native(range.map { RuntimeValue.native($0) }) }
            if let array = value.arrayValue { return .native(array) }
            return .native([value])
        }
        define("UUID") { _, _ in .native(UUID()) }
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
