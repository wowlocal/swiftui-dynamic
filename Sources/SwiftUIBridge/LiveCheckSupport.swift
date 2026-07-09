import SwiftInterpreter

/// LiveCheck's render probe: interpret a merged project, deep-render every
/// body (HeadlessVerifier mechanics), and collect every STRING argument in
/// the tree — scenario assertions check that fixture-derived content
/// (movie titles, status authors) actually reached the UI.
public enum LiveCheckSupport {
    /// Diagnostics from the last probe run — scenario failure messages
    /// surface them so the histogram names the next class precisely.
    public private(set) static var lastRootSymbol = ""
    public private(set) static var lastLifecycleFired = 0

    public static func renderedStrings(source: String) throws -> [String] {
        let interpreter = Interpreter(registry: TraceRegistry())
        do {
            try interpreter.run(source: source, lazyTopLevelGlobals: true)
        } catch {
            throw RuntimeError(message: "top-level threw: \(error)")
        }
        for delegateSymbol in interpreter.structSymbols
        where delegateSymbol.conformances.contains("NSApplicationDelegate")
            || delegateSymbol.conformances.contains("UIApplicationDelegate") {
            guard case .instance(let delegate)? = try? interpreter.instantiateRoot(delegateSymbol) else {
                continue
            }
            let hook = RuntimeValue.native(ChainedImplicitCall(
                base: .implicitMember("launch"), member: "notification", arguments: CallArguments()))
            _ = try? interpreter.callMethod(
                named: "applicationDidFinishLaunching", on: delegate, arguments: [hook])
        }
        // Prefer the app's own composition-root EXPRESSION (wrappers +
        // environment seeding evaluate for real, e.g. StoreProvider(store:)
        // around the tab view); fall back to instantiating the root symbol.
        var renderRoot: (() throws -> TraceNode)?
        if let rootExpression = interpreter.declaredRootViewExpression(),
           let value = try? interpreter.evaluateGlobalExpression(rootExpression) {
            if case .instance(let instance) = value {
                lastRootSymbol = "app:" + instance.symbol.name
                try interpreter.injectEnvironmentObjects(into: instance, models: [:])
                interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
                renderRoot = {
                    try TraceRegistry.node(interpreter.evaluateBody(of: instance))
                }
            } else if (try? TraceRegistry.node(value)) != nil {
                lastRootSymbol = "expr:" + rootExpression.trimmedDescription.prefix(40)
                renderRoot = {
                    try TraceRegistry.node(interpreter.evaluateGlobalExpression(rootExpression))
                }
            }
        }
        if renderRoot == nil {
            guard let symbol = interpreter.rootViewSymbol() else {
                throw RuntimeError(message: "no View-conforming struct found")
            }
            lastRootSymbol = symbol.name
            guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
                throw RuntimeError(message: "could not instantiate '\(symbol.name)'")
            }
            try interpreter.injectEnvironmentObjects(into: instance, models: [:])
            interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
            renderRoot = {
                try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            }
        }
        lastLifecycleFired = 0

        // The async-fetch pass (M2): render, FIRE retained `.task`/
        // `.onAppear` closures (fetched data lands in state), re-render and
        // recollect — repeat while new lifecycle work appears or the tree
        // grows (fetch → state → dependent fetch cascades), max 3 passes.
        var strings: [String] = []
        var firedCount = 0
        for _ in 0..<3 {
            let root = try renderRoot!()
            var passStrings: [String] = []
            var lifecycle: [ClosureValue] = []
            try collect(interpreter, root, into: &passStrings, lifecycle: &lifecycle)
            let grew = passStrings.count > strings.count
            strings = passStrings
            let pending = lifecycle.dropFirst(firedCount)
            if pending.isEmpty && !grew {
                break
            }
            for closure in pending {
                _ = try? interpreter.callBackgroundClosure(closure, arguments: [])
                lastLifecycleFired += 1
            }
            firedCount = lifecycle.count
        }
        return strings
    }

    private static func collect(
        _ interpreter: Interpreter, _ node: TraceNode, into strings: inout [String],
        lifecycle: inout [ClosureValue],
        environment: [String: Instance] = [:], depth: Int = 0
    ) throws {
        guard depth < 16 else { return }
        strings.append(contentsOf: node.args)
        lifecycle.append(contentsOf: node.lifecycle)
        var environment = environment
        environment.merge(node.environmentModels) { _, injected in injected }
        if let instance = node.instance {
            try interpreter.injectEnvironmentObjects(into: instance, models: environment)
            interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            try collect(interpreter, body, into: &strings, lifecycle: &lifecycle,
                        environment: environment, depth: depth + 1)
        }
        for child in node.children {
            try collect(interpreter, child, into: &strings, lifecycle: &lifecycle,
                        environment: environment, depth: depth + 1)
        }
    }
}
