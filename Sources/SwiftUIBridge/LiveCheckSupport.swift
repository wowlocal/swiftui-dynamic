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

    /// `afterActions:` — the interaction rung: after lifecycle passes,
    /// invoke up to N collected actions (each against a FRESH render, like
    /// HeadlessVerifier's click-through), then re-render and re-collect —
    /// with the live model store, an Add button's insert becomes a visible
    /// row.
    public static func renderedStrings(source: String, afterActions actionCount: Int = 0) throws -> [String] {
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
        // The @main App path: scene body as a BUILDER with the App as self
        // (multi-statement scenes, wrappers, env seeding all launch-faithful).
        if let scene = interpreter.declaredAppSceneRoot() {
            do {
                let views = try interpreter.sceneViews(app: scene.app, sceneBody: scene.sceneBody)
                if let first = views.first, (try? TraceRegistry.node(first)) != nil {
                    lastRootSymbol = "scene:" + scene.app.symbol.name
                    renderRoot = {
                        let fresh = try interpreter.sceneViews(app: scene.app, sceneBody: scene.sceneBody)
                        guard let view = fresh.first else {
                            throw RuntimeError(message: "scene produced no views")
                        }
                        return try TraceRegistry.node(view)
                    }
                }
            } catch {
                lastRootSymbol = "sceneBuilderError: \(error)"
            }
        }
        if renderRoot == nil, let declared = interpreter.declaredRootViewExpression() {
            // The App instance's stored/@StateObject properties evaluate
            // once (its init runs), then the scene expression sees them as
            // self — launch-faithful environment seeding.
            var appInstance: Instance?
            if let appSymbol = declared.app {
                do {
                    if case .instance(let app) = try interpreter.instantiateRoot(appSymbol) {
                        appInstance = app
                    }
                } catch {
                    lastRootSymbol = "appInitError: \(error)"
                }
            }
            let rootExpression = declared.expression
            var sceneValue: RuntimeValue?
            do {
                sceneValue = try interpreter.evaluateAppRootExpression(rootExpression, app: appInstance)
            } catch {
                lastRootSymbol = "sceneExprError: \(error)"
            }
            if let value = sceneValue {
            if case .instance(let instance) = value {
                lastRootSymbol = "app:" + instance.symbol.name
                try interpreter.injectEnvironmentObjects(into: instance, models: [:])
                interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
                renderRoot = {
                    try TraceRegistry.node(interpreter.evaluateBody(of: instance))
                }
            } else if (try? TraceRegistry.node(value)) != nil {
                lastRootSymbol = "expr:" + rootExpression.trimmedDescription.prefix(40)
                let app = appInstance
                renderRoot = {
                    try TraceRegistry.node(interpreter.evaluateAppRootExpression(rootExpression, app: app))
                }
            } else {
                lastRootSymbol = "sceneValueUnusable: \(value.stringified.prefix(60))"
            }
            }
        }
        if renderRoot == nil {
            guard let symbol = interpreter.rootViewSymbol() else {
                throw RuntimeError(message: "no View-conforming struct found")
            }
            if lastRootSymbol.hasPrefix("appInitError") || lastRootSymbol.hasPrefix("sceneExprError")
                || lastRootSymbol.hasPrefix("sceneValueUnusable") || lastRootSymbol.hasPrefix("sceneBuilderError") {
                lastRootSymbol += " → fallback:" + symbol.name
            } else if interpreter.declaredRootViewExpression() == nil {
                lastRootSymbol = "noDeclaredRoot → " + symbol.name
            } else {
                lastRootSymbol = symbol.name
            }
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
            var passActions: [ClosureValue] = []
            try collect(interpreter, root, into: &passStrings, lifecycle: &lifecycle, actions: &passActions)
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

        // Interaction rung: click through the first N actions.
        if actionCount > 0 {
            for position in 0..<actionCount {
                var current: [ClosureValue] = []
                var discardStrings: [String] = []
                var discardLifecycle: [ClosureValue] = []
                try collect(interpreter, try renderRoot!(), into: &discardStrings,
                            lifecycle: &discardLifecycle, actions: &current)
                guard !current.isEmpty else { break }
                // N interactions cycle through the available actions — a
                // single Add button tapped twice inserts twice.
                _ = try? interpreter.callClosure(current[position % current.count], arguments: [])
            }
            var finalStrings: [String] = []
            var discardLifecycle: [ClosureValue] = []
            var discardActions: [ClosureValue] = []
            try collect(interpreter, try renderRoot!(), into: &finalStrings,
                        lifecycle: &discardLifecycle, actions: &discardActions)
            strings = finalStrings
        }
        return strings
    }

    private static func collect(
        _ interpreter: Interpreter, _ node: TraceNode, into strings: inout [String],
        lifecycle: inout [ClosureValue],
        actions: inout [ClosureValue],
        environment: [String: Instance] = [:], depth: Int = 0
    ) throws {
        guard depth < 16 else { return }
        strings.append(contentsOf: node.args)
        lifecycle.append(contentsOf: node.lifecycle)
        actions.append(contentsOf: node.actions.values)
        var environment = environment
        environment.merge(node.environmentModels) { _, injected in injected }
        if let instance = node.instance {
            try interpreter.injectEnvironmentObjects(into: instance, models: environment)
            interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            try collect(interpreter, body, into: &strings, lifecycle: &lifecycle,
                        actions: &actions, environment: environment, depth: depth + 1)
        }
        for child in node.children {
            try collect(interpreter, child, into: &strings, lifecycle: &lifecycle,
                        actions: &actions, environment: environment, depth: depth + 1)
        }
    }
}
