import SwiftInterpreter

/// Headless full verification of a program: interpret, deep-render every View
/// body via the trace registry (with `.environmentObject` scoping threaded
/// down), then click every action against a fresh render and re-verify. Used
/// by the corpus tests and by ProjectCheck over external projects.
public enum HeadlessVerifier {
    public struct Report {
        public let nodeCount: Int
        public let actionsInvoked: Int
    }

    @discardableResult
    public static func verify(source: String, interactions: Bool = true) throws -> Report {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        guard let symbol = interpreter.rootViewSymbol() else {
            throw RuntimeError(message: "no View-conforming struct found")
        }
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            throw RuntimeError(message: "could not instantiate '\(symbol.name)'")
        }
        interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())

        var actions: [ClosureValue] = []
        let root = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        let nodeCount = try deepRender(interpreter, root, actions: &actions)

        var invoked = 0
        if interactions {
            // Click through the UI like a user: each action fires against a
            // FRESH render (stale trees may hold dead indices, exactly as in
            // real SwiftUI where old rows disappear).
            for position in 0..<actions.count {
                var current: [ClosureValue] = []
                let tree = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
                _ = try deepRender(interpreter, tree, actions: &current)
                guard position < current.count else { break }
                _ = try interpreter.callClosure(current[position], arguments: [])
                invoked += 1
            }
            var ignored: [ClosureValue] = []
            let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            _ = try deepRender(interpreter, rerendered, actions: &ignored)
        }
        return Report(nodeCount: nodeCount, actionsInvoked: invoked)
    }

    /// Recursively evaluates interpreted-View bodies and collects actions.
    /// `.environmentObject` injections recorded on a node scope its subtree.
    @discardableResult
    public static func deepRender(
        _ interpreter: Interpreter,
        _ node: TraceNode,
        actions: inout [ClosureValue],
        environment: [String: Instance] = [:],
        depth: Int = 0
    ) throws -> Int {
        guard depth < 16 else { return 1 }
        var count = 1
        var environment = environment
        environment.merge(node.environmentModels) { _, injected in injected }
        actions += node.actions.values
        if let instance = node.instance {
            try interpreter.injectEnvironmentObjects(into: instance, models: environment)
            interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            count += try deepRender(interpreter, body, actions: &actions, environment: environment, depth: depth + 1)
        }
        for child in node.children {
            count += try deepRender(interpreter, child, actions: &actions, environment: environment, depth: depth + 1)
        }
        return count
    }
}
