import Foundation
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
    /// Errors swallowed while firing lifecycle closures — the histogram's
    /// raw material (a silent `try?` here hides the next wall).
    public private(set) static var lastLifecycleErrors: [String] = []
    /// Diagnostic tracing: when set, each fired lifecycle closure prints its
    /// body head + outcome, so a silent absorb inside a deep fetch chain can
    /// be localized without touching the metric.
    public static var traceLifecycle = false
    /// The absorb histogram from the last probe — the demand list for the
    /// generated-members tier (BridgeGen --emit fills the biggest absorber).
    public private(set) static var lastAbsorbedHostMembers: [String: Int] = [:]

    /// `afterActions:` — the interaction rung: after lifecycle passes,
    /// invoke up to N collected actions (each against a FRESH render, like
    /// HeadlessVerifier's click-through), then re-render and re-collect —
    /// with the live model store, an Add button's insert becomes a visible
    /// row.
    public static func renderedStrings(source: String, afterActions actionCount: Int = 0) throws -> [String] {
        HeadlessVerifier.resetBridgeEnvironment()
        let interpreter = Interpreter(registry: TraceRegistry())
        // The live-probe contract: @State/@StateObject boxes persist per view
        // identity so the fetch pass sees .onAppear's writes.
        interpreter.persistentViewState = true
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
                LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
                renderRoot = {
                    LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
                    return try TraceRegistry.node(interpreter.evaluateBody(of: instance))
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
            LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
            renderRoot = {
                LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
                return try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            }
        }
        lastLifecycleFired = 0
        lastLifecycleErrors = []
        lastAbsorbedHostMembers = [:]

        // The async-fetch pass (M2): render, FIRE retained `.task`/
        // `.onAppear` closures (fetched data lands in state), re-render and
        // recollect — repeat while new lifecycle work appears or the tree
        // grows (fetch → state → dependent fetch cascades). Native renders
        // until quiescent; the cap only guards against ping-pong loops, and
        // the break below exits as soon as a pass adds nothing.
        var strings: [String] = []
        var firedCount = 0
        for renderPass in 0..<8 {
            // Deliver main-queue hops queued at the END of the previous
            // pass (a dispatch fired INSIDE another dispatch's delivery —
            // the AsyncAction execute → response-dispatch chain) BEFORE
            // rendering, so the quiescence check sees their state writes.
            if renderPass > 0 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                MainQueueDrain.drain()
            }
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
                if traceLifecycle {
                    let head = closure.body.description
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ⏎ ")
                    print("▶ lifecycle[\(lastLifecycleFired)]: \(head.prefix(110))")
                }
                do {
                    _ = try interpreter.callBackgroundClosure(closure, arguments: [])
                    if traceLifecycle { print("   ✓ completed") }
                } catch {
                    lastLifecycleErrors.append("\(error)")
                    if traceLifecycle { print("   ✗ \(error)") }
                }
                lastLifecycleFired += 1
            }
            firedCount = lifecycle.count
            // Drain main-queue hops before the next render pass:
            // `DispatchQueue.main.async` (SwiftUIFlux's Store.dispatch)
            // bridges through Task{@MainActor}, which never runs inside a
            // synchronous loop — a short RunLoop pump delivers them, like
            // the real main loop would between frames.
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            MainQueueDrain.drain()
        }

        if traceLifecycle {
            print("   ◇ strings (\(strings.count)):")
            for line in strings.prefix(1000) { print("     · \(line.prefix(80))") }
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
        lastAbsorbedHostMembers = interpreter.absorbedHostMembers
        if traceLifecycle {
            print("▶ tree strings (\(strings.count)):")
            for string in strings.prefix(60) {
                print("   · \(string.prefix(90))")
            }
        }
        return strings
    }

    private static func collect(
        _ interpreter: Interpreter, _ node: TraceNode, into strings: inout [String],
        lifecycle: inout [ClosureValue],
        actions: inout [ClosureValue],
        environment: [String: Instance] = [:], depth: Int = 0
    ) throws {
        // IceCubes' composition (scene → tabs → navigation → timeline →
        // list → rows) nests past 16; rows vanished silently at the old cap.
        guard depth < 48 else { return }
        strings.append(contentsOf: node.args)
        lifecycle.append(contentsOf: node.lifecycle)
        actions.append(contentsOf: node.actions.values)
        var environment = environment
        environment.merge(node.environmentModels) { _, injected in injected }
        if node.optionalCoverage {
            // Pushed-screen subtrees are best-effort: a failing destination
            // body skips (the screen never rendered), never fails the walk.
            do {
                var optionalStrings: [String] = []
                var optionalLifecycle: [ClosureValue] = []
                var optionalActions: [ClosureValue] = []
                let probe = TraceNode(kind: node.kind)
                probe.args = node.args
                probe.children = node.children
                probe.instance = node.instance
                probe.environmentModels = node.environmentModels
                try collectRequired(interpreter, probe, into: &optionalStrings,
                                    lifecycle: &optionalLifecycle, actions: &optionalActions,
                                    environment: environment, depth: depth)
                strings += optionalStrings
                lifecycle += optionalLifecycle
                actions += optionalActions
            } catch {
                // unreachable screen: contributes nothing
            }
            return
        }
        try collectRequired(interpreter, node, into: &strings, lifecycle: &lifecycle,
                            actions: &actions, environment: environment, depth: depth)
    }

    private static func collectRequired(
        _ interpreter: Interpreter, _ node: TraceNode, into strings: inout [String],
        lifecycle: inout [ClosureValue],
        actions: inout [ClosureValue],
        environment: [String: Instance] = [:], depth: Int = 0
    ) throws {
        if let instance = node.instance {
            if traceLifecycle, ["TimelineView", "TimelineListView", "StatusesListView"].contains(instance.symbol.name) {
                let vm = instance.box(for: "viewModel")?.value ?? instance.box(for: "fetcher")?.value ?? .void
                var vmID = "-"
                if case .instance(let model) = vm {
                    vmID = String(UInt(bitPattern: ObjectIdentifier(model).hashValue) % 100000)
                    if let state = model.box(for: "statusesState")?.value {
                        vmID += " state=" + String(state.stringified.prefix(40))
                    }
                }
                else { vmID = String(vm.stringified.prefix(30)) }
                print("   ⊙ \(instance.symbol.name) vm=\(vmID)")
            }
            try interpreter.injectEnvironmentObjects(into: instance, models: environment)
            interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
            LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
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
