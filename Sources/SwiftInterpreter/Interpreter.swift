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

    var locationConverter: SourceLocationConverter?
    var steps = 0
    /// Guards against `while true {}` freezing the UI: evaluation is main-actor.
    let stepBudget = 100_000

    public init(registry: HostRegistry? = nil) {
        self.registry = registry
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

    /// Parse and run a whole program: struct/func declarations are hoisted,
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
               decl.is(StructDeclSyntax.self) || decl.is(FunctionDeclSyntax.self) {
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

    /// Default + memberwise initialization (custom `init`s aren't supported):
    /// stored-property initializers run first, then labeled arguments override.
    public func instantiate(_ symbol: StructSymbol, with args: CallArguments, node: Syntax? = nil) throws -> RuntimeValue {
        let instance = Instance(symbol: symbol)
        for property in symbol.storedProperties {
            var value = RuntimeValue.void
            if let initializer = property.initializer {
                value = try evaluate(initializer, in: globals)
            }
            let box = Box(value)
            if property.isState {
                instance.stateBoxes[property.name] = box
            } else {
                instance.properties[property.name] = box
            }
        }
        for argument in args.arguments {
            guard let label = argument.label, let box = instance.box(for: label) else {
                let message = "argument '\(argument.label ?? "_")' doesn't match a stored property of '\(symbol.name)'"
                if let node { throw error(node, message) }
                throw RuntimeError(message: message)
            }
            box.value = argument.value
        }
        return .instance(instance)
    }

    /// Evaluate an instance's `body` computed property in ViewBuilder mode.
    /// Multiple top-level views are grouped by the registry (TupleView stand-in).
    public func evaluateBody(of instance: Instance) throws -> RuntimeValue {
        steps = 0
        guard let accessor = instance.symbol.computedProperties["body"] else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no body property")
        }
        let views = try collectBuilderViews(accessor, in: methodEnvironment(for: instance))
        if views.count == 1 { return views[0] }
        guard let registry else {
            throw RuntimeError(message: "no host registry configured")
        }
        return try registry.makeGroup(views)
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

    func methodEnvironment(for instance: Instance) -> Environment {
        let env = Environment(parent: globals)
        env.define("self", .instance(instance))
        return env
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
            throw error(node, "evaluation budget exceeded (possible infinite loop)")
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
