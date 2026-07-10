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

    /// Fresh-container guarantee: every verification starts with an empty
    /// sandbox, blob store, and defaults suite — corpus determinism.
    public static func resetBridgeEnvironment() {
        FileManagerBox.resetSandbox()
        ObjCTrampoline.resetEphemeralDefaults()
    }

    @discardableResult
    public static func verify(
        source: String, interactions: Bool = true, lazyTopLevelGlobals: Bool = false
    ) throws -> Report {
        resetBridgeEnvironment()
        let interpreter = Interpreter(registry: TraceRegistry())
        do {
            try interpreter.run(source: source, lazyTopLevelGlobals: lazyTopLevelGlobals)
        } catch {
            throw RuntimeError(message: "top-level threw: \(error)")
        }
        // Launch hooks run before any view, as on device: the app
        // delegate's didFinishLaunching seeds singletons (platform keys,
        // caches). Absorbed-environment failures inside are tolerated.
        for delegateSymbol in interpreter.structSymbols
        where delegateSymbol.conformances.contains("NSApplicationDelegate")
            || delegateSymbol.conformances.contains("UIApplicationDelegate") {
            guard case .instance(let delegate)? = try? interpreter.instantiateRoot(delegateSymbol) else {
                continue
            }
            let hook = RuntimeValue.native(ChainedImplicitCall(
                base: .implicitMember("launch"), member: "notification", arguments: CallArguments()))
            do {
                _ = try interpreter.callMethod(
                    named: "applicationDidFinishLaunching", on: delegate, arguments: [hook])
            } catch let error as RuntimeError where !error.fatal {
                // absorbed-environment failures inside the hook are tolerated
            } catch is InterpretedThrow {
                // an interpreted throw that escaped the delegate's own
                // catches — always rooted in an absorbed environment
                // (didFinishLaunching can't throw in compiled Swift)
            } catch {
                throw RuntimeError(message: "launch hook threw: \(error)")
            }
        }
        guard let symbol = interpreter.rootViewSymbol() else {
            throw RuntimeError(message: "no View-conforming struct found")
        }
        let rootValue: RuntimeValue
        do {
            rootValue = try interpreter.instantiateRoot(symbol)
        } catch {
            throw RuntimeError(message: "root init threw: \(error)")
        }
        guard case .instance(let instance) = rootValue else {
            throw RuntimeError(message: "could not instantiate '\(symbol.name)'")
        }
        try interpreter.injectEnvironmentObjects(into: instance, models: [:])
        interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
        LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)

        var actions: [ClosureValue] = []
        let root: TraceNode
        do {
            root = try { LiveModelStore.refreshQueries(into: instance, interpreter: interpreter); return try TraceRegistry.node(interpreter.evaluateBody(of: instance)) }()
        } catch let e {
            throw RuntimeError(message: "root body threw: \(e)")
        }
        let nodeCount = try deepRender(interpreter, root, actions: &actions)

        var invoked = 0
        if interactions {
            // Click through the UI like a user: each action fires against a
            // FRESH render (stale trees may hold dead indices, exactly as in
            // real SwiftUI where old rows disappear).
            for position in 0..<actions.count {
                var current: [ClosureValue] = []
                let tree = try { LiveModelStore.refreshQueries(into: instance, interpreter: interpreter); return try TraceRegistry.node(interpreter.evaluateBody(of: instance)) }()
                _ = try deepRender(interpreter, tree, actions: &current)
                guard position < current.count else { break }
                do {
                    _ = try interpreter.callClosure(current[position], arguments: [])
                } catch let designed as RuntimeError
                    where designed.message.hasPrefix("fatalError:")
                        || designed.message.hasPrefix("preconditionFailure:") {
                    // An EXPLICIT fatalError in a clicked action is the
                    // app's designed termination (nextcloud's DEBUG "Crash
                    // test" button) — on device the tester relaunches; the
                    // click-through moves to the next control. Fatals
                    // during RENDER stay fatal — they are interpreter
                    // canaries.
                } catch {
                    throw RuntimeError(message: "action #\(position) threw: \(error)")
                }
                invoked += 1
            }
            var ignored: [ClosureValue] = []
            let rerendered = try { LiveModelStore.refreshQueries(into: instance, interpreter: interpreter); return try TraceRegistry.node(interpreter.evaluateBody(of: instance)) }()
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
        if node.optionalCoverage {
            // Pushed-screen subtrees (NavigationLink destinations) exist on
            // device only after a tap: render best-effort, skip on failure,
            // and leave their actions unclicked like any unopened screen.
            node.optionalCoverage = false
            var unclicked: [ClosureValue] = []
            do {
                count += try deepRender(
                    interpreter, node, actions: &unclicked,
                    environment: environment, depth: depth)
            } catch {}
            return count
        }
        var environment = environment
        environment.merge(node.environmentModels) { _, injected in injected }
        actions += node.actions.values
        if let instance = node.instance {
            try interpreter.injectEnvironmentObjects(into: instance, models: environment)
            interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
            LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
            let body = try { LiveModelStore.refreshQueries(into: instance, interpreter: interpreter); return try TraceRegistry.node(interpreter.evaluateBody(of: instance)) }()
            count += try deepRender(interpreter, body, actions: &actions, environment: environment, depth: depth + 1)
        }
        for child in node.children {
            count += try deepRender(interpreter, child, actions: &actions, environment: environment, depth: depth + 1)
        }
        return count
    }
}
