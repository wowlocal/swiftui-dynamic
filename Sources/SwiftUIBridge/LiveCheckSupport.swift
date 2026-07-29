import Foundation
import SwiftInterpreter

public struct LiveCheckRenderResult: Sendable {
    public let strings: [String]
    public let rootSymbol: String
    public let lifecycleFired: Int
    public let lifecycleErrors: [String]
    public let absorbedHostMembers: [String: Int]
    public var networkRequests: [String]
}

/// Which native viewport transitions a headless live probe should model.
/// `.throughEnd` first reaches launch quiescence with the initial viewport,
/// then materializes the remaining rows as a user scroll would. Container
/// eligibility still comes from `TraceNode.initialLifecycleRowCapacity`; the
/// traversal never dispatches on a view, app, callback, or fixture identity.
public enum LiveCheckViewportTraversal: Sendable {
    case initial
    case throughEnd
}

/// Process-wide bridge defaults captured at the synchronous call site before
/// an async probe can yield to another test. The immutable snapshot then
/// follows the render and every source Task it creates.
public struct LiveCheckEnvironment: Sendable {
    public let networkPolicy: NetworkPolicy
    public let projectResourceRoot: String?
    public let buildConfiguration: InterpreterBuildConfiguration

    public init(
        networkPolicy: NetworkPolicy,
        projectResourceRoot: String?,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.networkPolicy = networkPolicy
        self.projectResourceRoot = projectResourceRoot
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Interpreter.interpretsAsPlatform,
                activeCompilationConditions:
                    Interpreter.interpretsWithCompilationConditions)
    }

    public static var current: LiveCheckEnvironment {
        LiveCheckEnvironment(
            networkPolicy: NetworkBridge.policy,
            projectResourceRoot: BundleBox.projectResourceRoot)
    }
}

/// LiveCheck's render probe: interpret a merged project, deep-render every
/// body (HeadlessVerifier mechanics), and collect every STRING argument in
/// the tree — scenario assertions check that fixture-derived content
/// (movie titles, status authors) actually reached the UI.
public enum LiveCheckSupport {
    private static var probeIsRunning = false
    private static var probeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Mutable traversal state for one viewport-materialized container. A
    /// ForEach fan establishes logical row boundaries; later siblings in the
    /// same builder (the common trailing pagination row) consume the same
    /// launch viewport. Nested collections inside a row receive no cursor and
    /// therefore cannot consume their parent's row budget.
    private final class InitialLifecycleViewport {
        var remainingRows: Int
        var encounteredRows = false

        init(capacity: Int) {
            remainingRows = capacity
        }

        func consumeRow() -> Bool {
            defer { if remainingRows > 0 { remainingRows -= 1 } }
            return remainingRows > 0
        }
    }

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
    /// Optional type filter for deep-render diagnostics. A comma-separated
    /// list traces matching interpreted View boundaries; `*` traces all of
    /// them. Keeping selection outside the bridge avoids app-name branches in
    /// a reusable traversal primitive.
    private static let tracedViewTypes: Set<String>? = ProcessInfo.processInfo
        .environment["INTERP_TRACE_VIEW_TYPES"]
        .map { Set($0.split(separator: ",").map(String.init)) }
    /// The absorb histogram from the last probe — the demand list for the
    /// generated-members tier (BridgeGen --emit fills the biggest absorber).
    public private(set) static var lastAbsorbedHostMembers: [String: Int] = [:]

    /// `afterActions:` — the interaction rung: after lifecycle passes,
    /// invoke up to N collected actions (each against a FRESH render, like
    /// HeadlessVerifier's click-through), then re-render and re-collect —
    /// with the live model store, an Add button's insert becomes a visible
    /// row.
    public static func renderedStrings(
        source: String,
        afterActions actionCount: Int = 0,
        viewportTraversal: LiveCheckViewportTraversal = .initial,
        environment: LiveCheckEnvironment = .current
    ) async throws -> [String] {
        try await render(
            source: source,
            afterActions: actionCount,
            viewportTraversal: viewportTraversal,
            environment: environment).strings
    }

    /// Result-scoped diagnostics remain attached to the render that produced
    /// them even when another async test begins immediately after this call.
    public static func render(
        source: String,
        afterActions actionCount: Int = 0,
        viewportTraversal: LiveCheckViewportTraversal = .initial,
        environment: LiveCheckEnvironment = .current
    ) async throws -> LiveCheckRenderResult {
        await acquireProbe()
        defer { releaseProbe() }
        let scoped = try await BundleBox.withProjectResourceRoot(
            environment.projectResourceRoot
        ) {
            try await NetworkBridge.withIsolatedReplay(
                policy: environment.networkPolicy
            ) {
                try await renderInCurrentReplayScope(
                    source: source,
                    afterActions: actionCount,
                    viewportTraversal: viewportTraversal,
                    buildConfiguration: environment.buildConfiguration,
                    projectResourceRoot: environment.projectResourceRoot)
            }
        }
        var result = scoped.value
        result.networkRequests = scoped.requestLog
        return result
    }

    private static func acquireProbe() async {
        if !probeIsRunning {
            probeIsRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            probeWaiters.append(continuation)
        }
    }

    private static func releaseProbe() {
        if probeWaiters.isEmpty {
            probeIsRunning = false
        } else {
            probeWaiters.removeFirst().resume()
        }
    }

    private static func renderInCurrentReplayScope(
        source: String,
        afterActions actionCount: Int,
        viewportTraversal: LiveCheckViewportTraversal,
        buildConfiguration: InterpreterBuildConfiguration,
        projectResourceRoot: String?
    ) async throws -> LiveCheckRenderResult {
        HeadlessVerifier.resetBridgeEnvironment()
        let interpreter = Interpreter(
            registry: TraceRegistry(
                projectResourceRoot: projectResourceRoot),
            buildConfiguration: buildConfiguration)
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
                interpreter.injectEnvironmentValues(
                    into: instance,
                    values: InterpretedEnvironment.defaults(
                        platformName:
                            interpreter.buildConfiguration.platformName))
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
            interpreter.injectEnvironmentValues(
                into: instance,
                values: InterpretedEnvironment.defaults(
                    platformName: interpreter.buildConfiguration.platformName))
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
        var firedLifecycle: Set<TraceLifecycleIdentity> = []
        let materializationPhases =
            viewportTraversal == .throughEnd ? [false, true] : [false]
        var hasRendered = false
        for materializesAllRows in materializationPhases {
            for _ in 0..<8 {
                // Deliver main-queue hops queued at the END of the previous
                // pass (a dispatch fired INSIDE another dispatch's delivery —
                // the AsyncAction execute → response-dispatch chain) BEFORE
                // rendering, so the quiescence check sees their state writes.
                if hasRendered {
                    await advanceAsyncLifecycleWork()
                }
                let root = try renderRoot!()
                var passStrings: [String] = []
                var lifecycle: [TraceLifecycle] = []
                var passActions: [ClosureValue] = []
                try collect(
                    interpreter, root, into: &passStrings,
                    lifecycle: &lifecycle, actions: &passActions,
                    materializesAllLifecycleRows: materializesAllRows)
                hasRendered = true
                let grew = passStrings.count > strings.count
                strings = passStrings
                let pending = lifecycle.filter {
                    firedLifecycle.insert($0.identity).inserted
                }
                if pending.isEmpty && !grew {
                    break
                }
                for entry in pending {
                    let closure = entry.closure
                    if traceLifecycle {
                        let head = closure.body.description
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\n", with: " ⏎ ")
                        print("▶ lifecycle[\(lastLifecycleFired)]: \(head.prefix(110))")
                    }
                    do {
                        if entry.isAsyncAction {
                            _ = try await interpreter.callSwiftUITask(
                                closure, arguments: [])
                        } else {
                            _ = try interpreter.callHostCallback(
                                closure, arguments: [])
                        }
                        if traceLifecycle { print("   ✓ completed") }
                    } catch {
                        lastLifecycleErrors.append("\(error)")
                        if traceLifecycle { print("   ✗ \(error)") }
                    }
                    lastLifecycleFired += 1
                }
                // Drain main-queue hops before the next render pass:
                // Source Tasks and deterministic main-queue callbacks alternate:
                // yield the actor so newly-created Tasks reach their first
                // suspension, drain retained callbacks, then yield once more so
                // resumed Tasks can publish state before the next render pass.
                await advanceAsyncLifecycleWork()
            }
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
                var discardLifecycle: [TraceLifecycle] = []
                try collect(interpreter, try renderRoot!(), into: &discardStrings,
                            lifecycle: &discardLifecycle, actions: &current)
                guard !current.isEmpty else { break }
                // N interactions cycle through the available actions — a
                // single Add button tapped twice inserts twice.
                _ = try? interpreter.callHostCallback(
                    current[position % current.count], arguments: [])
                await advanceAsyncLifecycleWork()
            }
            var finalStrings: [String] = []
            var discardLifecycle: [TraceLifecycle] = []
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
        return LiveCheckRenderResult(
            strings: strings,
            rootSymbol: lastRootSymbol,
            lifecycleFired: lastLifecycleFired,
            lifecycleErrors: lastLifecycleErrors,
            absorbedHostMembers: lastAbsorbedHostMembers,
            networkRequests: [])
    }

    private static func advanceAsyncLifecycleWork() async {
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(10))
            MainQueueDrain.drain()
        }
    }

    private static func collect(
        _ interpreter: Interpreter, _ node: TraceNode, into strings: inout [String],
        lifecycle: inout [TraceLifecycle],
        actions: inout [ClosureValue],
        environment: [String: Instance] = [:], depth: Int = 0,
        lifecycleEnabled: Bool = true,
        initialViewport: InitialLifecycleViewport? = nil,
        materializesAllLifecycleRows: Bool = false
    ) throws {
        // Keep a finite guard for malformed recursive Views while allowing
        // valid type-erased branches to nest beyond ordinary app-shell depth.
        guard depth < 128 else { return }
        strings.append(contentsOf: node.args)
        if lifecycleEnabled {
            lifecycle.append(contentsOf: node.lifecycle)
        }
        actions.append(contentsOf: node.actions.values)
        let initialViewport = materializesAllLifecycleRows
            ? nil
            : node.initialLifecycleRowCapacity.map {
                InitialLifecycleViewport(capacity: $0)
            } ?? initialViewport
        var environment = environment
        environment.merge(node.environmentModels) { _, injected in injected }
        if node.optionalCoverage {
            // Pushed-screen subtrees are best-effort: a failing destination
            // body skips (the screen never rendered), never fails the walk.
            do {
                var optionalStrings: [String] = []
                var optionalLifecycle: [TraceLifecycle] = []
                var optionalActions: [ClosureValue] = []
                let probe = TraceNode(kind: node.kind)
                probe.args = node.args
                probe.children = node.children
                probe.instance = node.instance
                probe.environmentModels = node.environmentModels
                probe.initialLifecycleRowCapacity =
                    node.initialLifecycleRowCapacity
                try collectRequired(interpreter, probe, into: &optionalStrings,
                                    lifecycle: &optionalLifecycle, actions: &optionalActions,
                                    environment: environment, depth: depth,
                                    lifecycleEnabled: lifecycleEnabled,
                                    initialViewport: initialViewport,
                                    materializesAllLifecycleRows:
                                        materializesAllLifecycleRows)
                strings += optionalStrings
                lifecycle += optionalLifecycle
                actions += optionalActions
            } catch {
                // unreachable screen: contributes nothing
            }
            return
        }
        try collectRequired(interpreter, node, into: &strings, lifecycle: &lifecycle,
                            actions: &actions, environment: environment, depth: depth,
                            lifecycleEnabled: lifecycleEnabled,
                            initialViewport: initialViewport,
                            materializesAllLifecycleRows:
                                materializesAllLifecycleRows)
    }

    private static func collectRequired(
        _ interpreter: Interpreter, _ node: TraceNode, into strings: inout [String],
        lifecycle: inout [TraceLifecycle],
        actions: inout [ClosureValue],
        environment: [String: Instance] = [:], depth: Int = 0,
        lifecycleEnabled: Bool = true,
        initialViewport: InitialLifecycleViewport? = nil,
        materializesAllLifecycleRows: Bool = false
    ) throws {
        if let instance = node.instance {
            if traceLifecycle, let tracedViewTypes,
               tracedViewTypes.contains("*")
                || tracedViewTypes.contains(instance.symbol.name) {
                print("   ⊙ view[\(depth)] \(instance.symbol.name)")
            }
            try interpreter.injectEnvironmentObjects(into: instance, models: environment)
            interpreter.injectEnvironmentValues(
                into: instance,
                values: InterpretedEnvironment.defaults(
                    platformName: interpreter.buildConfiguration.platformName))
            LiveModelStore.refreshQueries(into: instance, interpreter: interpreter)
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            try collect(interpreter, body, into: &strings, lifecycle: &lifecycle,
                        actions: &actions, environment: environment, depth: depth + 1,
                        lifecycleEnabled: lifecycleEnabled,
                        initialViewport: initialViewport,
                        materializesAllLifecycleRows:
                            materializesAllLifecycleRows)
        }
        if node.kind == "ForEach", let initialViewport {
            initialViewport.encounteredRows = true
            for child in node.children {
                let rowIsVisible = initialViewport.consumeRow()
                try collect(
                    interpreter, child, into: &strings,
                    lifecycle: &lifecycle, actions: &actions,
                    environment: environment, depth: depth + 1,
                    lifecycleEnabled: lifecycleEnabled && rowIsVisible,
                    initialViewport: nil,
                    materializesAllLifecycleRows:
                        materializesAllLifecycleRows)
            }
            return
        }
        for child in node.children {
            let childConsumesRow = initialViewport?.encounteredRows == true
            let childIsVisible = childConsumesRow
                ? initialViewport!.consumeRow() : true
            try collect(interpreter, child, into: &strings, lifecycle: &lifecycle,
                        actions: &actions, environment: environment, depth: depth + 1,
                        lifecycleEnabled: lifecycleEnabled && childIsVisible,
                        initialViewport: childConsumesRow ? nil : initialViewport,
                        materializesAllLifecycleRows:
                            materializesAllLifecycleRows)
        }
    }
}
