import AppKit
import SwiftUI
import SwiftInterpreter

/// Trace-mode stand-in for GeometryProxy: SwiftUI only creates real proxies
/// during layout, so headless verification uses an honest fixed canvas.
struct GeometryProxyStub {
    let size = CGSize(width: 390, height: 844)
}

/// Trace-mode stand-in for TimelineView's context.
struct TimelineContextStub {
    let date = Date()
}

/// Trace-mode stand-in for ScrollViewProxy (scrollTo is a no-op headlessly).
struct ScrollViewProxyStub {}

/// `MapReader { proxy in … }` — no map exists headlessly (or without
/// MapKit); coordinate conversions honestly return nil.
struct MapProxyStub {}

/// `Canvas { context, size in … }` headlessly: draw commands are accepted
/// and ignored (there is no surface to draw on), so wave/particle renderers
/// execute their math without a GPU.
struct GraphicsContextStub {}

/// `Path { path in … }` — accumulates a REAL Path from interpreted draw
/// commands, so user Shape structs (`func path(in:) -> Path`) render their
/// actual geometry. Unknown commands are accepted inertly.
final class PathDrawStub {
    var path = Path()

    func apply(_ command: String, _ args: CallArguments) {
        func point(_ value: RuntimeValue?) -> CGPoint? {
            if case .host(let any)? = value { return any as? CGPoint }
            return nil
        }
        func rect(_ value: RuntimeValue?) -> CGRect? {
            if case .host(let any)? = value { return any as? CGRect }
            return nil
        }
        switch command {
        case "move":
            if let to = point(args.labeled("to")) { path.move(to: to) }
        case "addLine":
            if let to = point(args.labeled("to")) { path.addLine(to: to) }
        case "addCurve":
            if let to = point(args.labeled("to")),
               let c1 = point(args.labeled("control1")),
               let c2 = point(args.labeled("control2")) {
                path.addCurve(to: to, control1: c1, control2: c2)
            }
        case "addQuadCurve":
            if let to = point(args.labeled("to")), let control = point(args.labeled("control")) {
                path.addQuadCurve(to: to, control: control)
            }
        case "addArc":
            if let center = point(args.labeled("center")),
               let radius = try? Coerce.cgFloat(args.labeled("radius") ?? .native(0.0)),
               let start = try? Coerce.angle(args.labeled("startAngle") ?? .native(0.0)),
               let end = try? Coerce.angle(args.labeled("endAngle") ?? .native(0.0)) {
                path.addArc(center: center, radius: radius, startAngle: start, endAngle: end,
                            clockwise: args.labeled("clockwise")?.boolValue ?? false)
            }
        case "addRect":
            if let r = rect(args.labeled("in") ?? args.positional(0)) { path.addRect(r) }
        case "addEllipse":
            if let r = rect(args.labeled("in") ?? args.positional(0)) { path.addEllipse(in: r) }
        case "closeSubpath":
            path.closeSubpath()
        case "strokedPath":
            var style = StrokeStyle()
            if case .host(let any)? = args.positional(0), let real = any as? StrokeStyle {
                style = real
            }
            path = path.strokedPath(style)
        case "addLines":
            if let points = args.positional(0)?.arrayValue {
                path.addLines(points.compactMap {
                    if case .host(let p) = $0 { return p as? CGPoint }
                    return nil
                })
            }
        default:
            break // other draw commands accepted inertly
        }
    }
}

/// A real SwiftUI Shape whose `path(in:)` delegates to the interpreted
/// method — user `struct WaterWave: Shape` draws its actual geometry.
/// The carrier keeps non-Sendable interpreter refs behind an @unchecked
/// wall; path(in:) is a nonisolated requirement but SwiftUI calls it on
/// the main thread during layout, so assumeIsolated holds.
private final class ShapeCarrier: @unchecked Sendable {
    let instance: Instance
    let interpreter: Interpreter

    nonisolated init(instance: Instance, interpreter: Interpreter) {
        self.instance = instance
        self.interpreter = interpreter
    }
}

struct InterpretedShape: Shape {
    private let carrier: ShapeCarrier

    init(instance: Instance, interpreter: Interpreter) {
        carrier = ShapeCarrier(instance: instance, interpreter: interpreter)
    }

    nonisolated func path(in rect: CGRect) -> Path {
        MainActor.assumeIsolated {
            do {
                let result = try carrier.interpreter.callMethod(
                    named: "path", on: carrier.instance, arguments: [.native(rect)])
                if case .host(let any) = result, let stub = any as? PathDrawStub {
                    return stub.path
                }
                if case .host(let any) = result, let real = any as? Path {
                    return real
                }
                return Path()
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: carrier.instance.symbol.name)
                return Path()
            } catch {
                return Path()
            }
        }
    }
}

/// iOS code reads `UIScreen.main.bounds`; the honest macOS analog is the main
/// screen's frame (fixed canvas headlessly).
struct ScreenStub {
    var bounds: CGRect {
        CGRect(origin: .zero, size: NSScreen.main?.frame.size ?? CGSize(width: 390, height: 844))
    }

    /// `NSScreen.main?.visibleFrame` — the real screen when there is one,
    /// a laptop-shaped rect headlessly.
    var visibleFrame: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
    }

    var frame: CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

/// `UIApplication.shared.windows.first?.safeAreaInsets…` — one window with
/// zero insets is the honest macOS analog.
struct AppStub {}
struct WindowStub {}
struct WindowSceneStub {}

/// UIKit hosting island (`window.rootViewController`, its `.view`, …):
/// property writes round-trip, unknown reads/calls chain more stubs — the
/// hosted view-controller machinery is inert but configurable.
final class UIKitStub: InertCallable {
    var config: [String: RuntimeValue] = [:]
    /// Host type/protocol names this stub STANDS FOR (`Task {…}` returns a
    /// stub playing ["Task", "Cancellable"]) so user extensions dispatch.
    var roles: [String] = []

    init(roles: [String] = []) {
        self.roles = roles
    }
}

/// `DispatchQueue.main` — async dispatches through the real main queue.
struct MainQueueStub {}

/// Deliveries queued by `DispatchQueue.main.async`: a Task drains them on
/// the live main loop, and the render probe drains SYNCHRONOUSLY between
/// passes — a task spawned from within another task's delivery would
/// otherwise sit past the probe's RunLoop pumps (the SwiftUIFlux
/// dispatch-inside-dispatch genre).
public enum MainQueueDrain {
    /// Interactive sessions (the demo app) run real wall-clock timers for
    /// positive asyncAfter delays; headless probes (Project/Test/LiveCheck)
    /// deliver bounded delays on the next drain instead — a probe frame
    /// never spans real time.
    public static var schedulesRealTimers = false
    static var pending: [ActionValue] = []
    /// Bounded asyncAfter deliveries (URLProtocol mocks' loadingTime).
    /// Each runs AT MOST ONCE per drain — a delayed action that
    /// re-schedules itself (nextcloud's retry loop) waits for the NEXT
    /// drain instead of spinning this one.
    static var delayedPending: [ActionValue] = []
    /// A probe frame spans FINITE time: self-rescheduling retries fire a
    /// bounded number of times per verification, then go quiet (LiveCheck
    /// pumps drain dozens of times per pass — unbounded retries turned a
    /// 90s board into 5+ minutes).
    static var delayedFireBudget = 64

    public static func drain() {
        runZeroDelay()
        guard !delayedPending.isEmpty else { return }
        let delayed = delayedPending
        delayedPending = []
        for action in delayed {
            guard delayedFireBudget > 0 else {
                delayedPending.removeAll()
                return
            }
            delayedFireBudget -= 1
            action.run()
            runZeroDelay()
        }
    }

    /// Per-verification isolation: DELAYED deliveries from one program
    /// must never fire inside the next (corpus determinism). Zero-delay
    /// items stay: they self-drain within a tick, and clearing them races
    /// CONCURRENT unit tests' in-flight deliveries (Swift Testing
    /// interleaves async tests on the main actor).
    public static func reset() {
        delayedPending = []
        delayedFireBudget = 64
    }

    private static func runZeroDelay() {
        while !pending.isEmpty {
            let batch = pending
            pending = []
            for action in batch { action.run() }
        }
    }
}

/// Members on host-native values — shared by the real and trace registries
/// via their `hostMember` hooks. Numbers come back as Double so interpreted
/// arithmetic works on them.
func bridgeHostMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let member = hostObjectMember(name, on: value) {
        return member
    }
    if let member = networkBridgeMember(name, on: value) {
        return member
    }
    // The generated Foundation tier (BridgeGen --emit over the SDK's
    // swiftinterface) serves value-type members no hand box claimed.
    if let member = GeneratedMembers.member(name, on: value) {
        return member
    }
    if let member = objcTrampolineMember(name, on: value) {
        return member
    }
    // Gesture chains: `.onChanged {}` / `.onEnded {}` accumulate interpreted
    // closures on the stub; `.gesture` later attaches the real gesture.
    if let gesture = value as? GestureBox, name == "onChanged" || name == "onEnded" {
        return .hostFunction(HostFunction(name: name) { args, _ in
            guard case .closure(let closure)? = args.arguments.first?.value else {
                return .native(gesture)
            }
            return .native(gesture.chained(name, closure))
        })
    }
    if let drag = value as? DragGesture.Value {
        switch name {
        case "translation": return .native(drag.translation)
        case "location": return .native(drag.location)
        case "startLocation": return .native(drag.startLocation)
        case "predictedEndTranslation": return .native(drag.predictedEndTranslation)
        case "predictedEndLocation": return .native(drag.predictedEndLocation)
        case "velocity": return .native(drag.velocity)
        case "time": return .native(drag.time)
        default: break
        }
    }
    if let gradient = value as? AnyGradient {
        if name == "opacity" {
            return .hostFunction(HostFunction(name: "opacity") { args, _ in
                .native(AnyShapeStyle(gradient.opacity(args.positional(0)?.doubleValue ?? 1)))
            })
        }
    }
    if let resolved = value as? Color.Resolved {
        switch name {
        case "red": return .native(Double(resolved.red))
        case "green": return .native(Double(resolved.green))
        case "blue": return .native(Double(resolved.blue))
        case "opacity": return .native(Double(resolved.opacity))
        case "cgColor": return .native(resolved.cgColor)
        default: return nil
        }
    }
    if let color = value as? Color {
        switch name {
        case "resolve":
            // The modern resolution API — real components in a default
            // environment.
            return .hostFunction(HostFunction(name: "resolve") { _, _ in
                .native(color.resolve(in: EnvironmentValues()))
            })
        case "opacity":
            return .hostFunction(HostFunction(name: "opacity") { args, _ in
                .native(color.opacity(args.positional(0)?.doubleValue ?? 1))
            })
        case "gradient":
            return .native(color.gradient)
        default:
            break
        }
    }
    if let marker = value as? HostTypeMarker {
        // `Color.white`, `Color.gray` — real Color values, so user
        // `extension Color { … }` members can dispatch on them.
        if marker.name == "Color", let color = Coerce.colorLike(.implicitMember(name)) {
            return .native(color)
        }
        switch (marker.name, name) {
        case ("ViewBuilder", "buildEither"):
            // TCA's IfLetStore shim calls the compiler-reserved statics as
            // API: `ViewBuilder.buildEither(first: content)` IS the content
            // (_ConditionalContent is invisible to rendering).
            return .hostFunction(HostFunction(name: name) { args, _ in
                args.labeled("first") ?? args.labeled("second") ?? args.positional(0) ?? .void
            })
        case ("ViewBuilder", "buildBlock"), ("ViewBuilder", "buildExpression"),
             ("ViewBuilder", "buildOptional"), ("ViewBuilder", "buildIf"),
             ("ViewBuilder", "buildLimitedAvailability"):
            return .hostFunction(HostFunction(name: name) { args, _ in
                let views = args.arguments.map(\.value)
                if views.count == 1 { return views[0] }
                return .native(views) // builder-content shape ([views])
            })
        case ("TimeZone", "current"), ("TimeZone", "autoupdatingCurrent"):
            return .native(TimeZone.current)
        case ("Bundle", "module"):
            // SPM resource bundles resolve against the merge's project
            // root — the committed files ARE what Bundle.module ships.
            return .native(BundleBox(bundle: .main))
        case ("Bundle", "main"):
            // The host process IS real (the uname doctrine): path-walking
            // idioms (locateHostBundleURL's climb to "/") terminate on a
            // real bundle URL. Resource lookups on the box absorb.
            return .native(BundleBox(bundle: .main))
        case ("UIScreen", "main"), ("NSScreen", "main"):
            return .native(ScreenStub())
        case ("DispatchQueue", "main"):
            return .native(MainQueueStub())
        case ("UIApplication", "shared"), ("NSApplication", "shared"):
            return .native(AppStub())
        case ("CGSize", "zero"):
            return .native(CGSize.zero)
        case ("CGPoint", "zero"):
            return .native(CGPoint.zero)
        case ("CGRect", "zero"):
            return .native(CGRect.zero)
        case ("Swift", _), ("Foundation", _):
            // Module-qualified stdlib references (`Swift.Duration`): the
            // module marker unwraps to the member's own type marker.
            return .native(HostTypeMarker(name: name))
        case ("Locale", "preferredLanguages"):
            // Stdlib statics through a SHADOWING app enum (the Duration
            // pattern): the real host value.
            return .native(Locale.preferredLanguages.map { RuntimeValue.native($0) })
        case ("Locale", "current"):
            return .native(Locale.current)
        case ("Duration", "seconds"), ("Duration", "milliseconds"),
             ("Duration", "microseconds"), ("Duration", "nanoseconds"):
            // Stdlib Duration statics reached through an app enum SHADOWING
            // the bare name (IceCubes' Env.Duration): the typed clock marker
            // Builtins already reads (.seconds(3) → 3.0 in arithmetic).
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(ImplicitMemberCall(name: name, arguments: args))
            })
        case ("Double", "zero"), ("CGFloat", "zero"), ("TimeInterval", "zero"):
            return .native(0.0)
        case ("Int", "zero"):
            return .native(0)
        case ("Double", "infinity"), ("CGFloat", "infinity"):
            return .native(Double.infinity)
        case ("Double", "pi"), ("CGFloat", "pi"):
            return .native(Double.pi)
        case ("UInt64", "max"):
            return .native(UInt64.max)
        case ("Double", "random"), ("CGFloat", "random"), ("Int", "random"), ("TimeInterval", "random"):
            let wantsInt = marker.name == "Int"
            return .hostFunction(HostFunction(name: "random") { args, ctx in
                let argument = args.labeled("in") ?? args.positional(0)
                // `random(in:using: &generator)` — the REAL stdlib algorithm
                // over the INTERPRETED generator (exact native parity: the
                // proxy's next() calls the interpreted next()).
                if ProcessInfo.processInfo.environment["RNG_TRACE"] != nil {
                    FileHandle.standardError.write(Data("   ⚙ random wantsInt=\(wantsInt) using=\(String(describing: args.labeled("using"))) arg=\(String(describing: argument))\n".utf8))
                }
                if let interpreter = ctx as? Interpreter,
                   let generator = interpreter.generatorInstance(from: args.labeled("using")) {
                    var proxy = InterpretedGeneratorProxy(interpreter: interpreter, generator: generator)
                    if wantsInt {
                        if let range = argument?.rangeValue?.halfOpenIntRange {
                            return .native(Int.random(in: range, using: &proxy))
                        }
                        if let range = argument?.rangeValue?.closedIntRange {
                            return .native(Int.random(in: range, using: &proxy))
                        }
                        throw RuntimeError(message: "Int.random(in:using:) needs an integer range")
                    }
                    if let range = argument?.rangeValue?.halfOpenDoubleRange {
                        return .native(Double.random(in: range, using: &proxy))
                    }
                    if let range = argument?.rangeValue?.closedDoubleRange {
                        return .native(Double.random(in: range, using: &proxy))
                    }
                    throw RuntimeError(message: "random(in:using:) needs a numeric range")
                }
                if wantsInt {
                    if let range = argument?.rangeValue?.halfOpenIntRange {
                        return .native(Int.random(in: range))
                    }
                    if let range = argument?.rangeValue?.closedIntRange {
                        return .native(Int.random(in: range))
                    }
                    throw RuntimeError(message: "Int.random(in:) needs an integer range")
                }
                if let range = argument?.rangeValue?.halfOpenDoubleRange {
                    return .native(Double.random(in: range))
                }
                if let range = argument?.rangeValue?.closedDoubleRange {
                    return .native(Double.random(in: range))
                }
                throw RuntimeError(message: "Double.random(in:) needs a numeric range")
            })
        case ("Result", "success"), ("Result", "failure"):
            // Annotation-typed implicit members (`: Result<T, Error> =
            // .success(x)`, mock response arrays) construct the carrier.
            let isSuccess = name == "success"
            return .hostFunction(HostFunction(name: name) { args, _ in
                let payload = args.positional(0) ?? .void
                return .native(ResultBox(isSuccess ? .success(payload) : .failure(payload)))
            })
        case ("Color", _), ("UIColor", _), ("NSColor", _):
            // Asset-catalog accessors (SwiftGen's `Color.haPrimary`) are
            // build-time generated — no source can ever declare them, so a
            // missing lowercase color static reads as a deterministic
            // placeholder (assets resolve only on device).
            guard name.first?.isLowercase == true else { return nil }
            return .native(SwiftUI.Color.gray)
        default:
            return nil
        }
    }
    if let stub = value as? UIKitStub {
        if let stored = stub.config[name] { return stored }
        // Geometry members read real fresh-layout values so CGRect/CGPoint
        // math works; everything else reads as a fresh stub. Both memoize
        // so writes persist (`vc.view.tag = 7` then `vc.view.tag`); calling
        // a stub is also inert (see the evaluator's invoke fallback).
        let fresh: RuntimeValue
        switch name {
        case "bounds", "frame": fresh = .native(CGRect.zero)
        case "center", "contentOffset": fresh = .native(CGPoint.zero)
        case "contentSize": fresh = .native(CGSize.zero)
        default: fresh = .native(UIKitStub())
        }
        stub.config[name] = fresh
        return fresh
    }
    if value is AppStub {
        switch name {
        case "run", "terminate", "activate", "deactivate", "stop", "finishLaunching":
            // The render pipeline IS the run loop — lifecycle calls no-op.
            return .hostFunction(HostFunction(name: name) { _, _ in .void })
        case "alternateIconName":
            return .none(wrappedTypeName: "String") // fresh install: primary icon
        case "setAlternateIconName":
            return .hostFunction(HostFunction(name: name) { _, _ in .void })
        case "windows": return .native([RuntimeValue.native(WindowStub())])
        case "connectedScenes": return .native([RuntimeValue.native(WindowSceneStub())])
        case "mainWindow", "keyWindow": return .native(WindowStub())
        case "canOpenURL":
            // URL schemes resolve on real devices; the richer branch renders.
            return .hostFunction(HostFunction(name: "canOpenURL") { _, _ in .native(true) })
        case "open":
            return .hostFunction(HostFunction(name: "open") { _, _ in .void })
        case "terminate":
            // Quitting the host would kill the verifier/demo — inert.
            return .hostFunction(HostFunction(name: "terminate") { _, _ in .void })
        case "sendAction":
            // Keyboard dismissal (`sendAction(#selector(resignFirstResponder)…)`)
            // and responder-chain pokes — no responder chain exists; inert.
            return .hostFunction(HostFunction(name: "sendAction") { _, _ in .void })
        default: return nil
        }
    }
    if value is WindowSceneStub {
        switch name {
        case "activationState": return .implicitMember("foregroundActive")
        case "screen": return .native(ScreenStub())
        case "keyWindow", "windows": return name == "windows"
            ? .native([RuntimeValue.native(WindowStub())])
            : .native(WindowStub())
        default: return nil
        }
    }
    if value is WindowStub {
        if name == "safeAreaInsets" { return .native(EdgeInsets()) }
        if name == "isKeyWindow" { return .native(true) } // ours is the only window
        if name == "frame" || name == "bounds" { return .native(ScreenStub().bounds) }
        if name == "rootViewController" || name == "rootController" {
            return .native(UIKitStub())
        }
        if name == "tag" { return .native(0) }
        if name == "close" {
            return .hostFunction(HostFunction(name: "close") { _, _ in .void })
        }
        return nil
    }
    if let insets = value as? EdgeInsets {
        switch name {
        case "top": return .native(Double(insets.top))
        case "leading", "left": return .native(Double(insets.leading))
        case "bottom": return .native(Double(insets.bottom))
        case "trailing", "right": return .native(Double(insets.trailing))
        default: return nil
        }
    }
    if value is ScreenStub {
        switch name {
        case "bounds": return .native(ScreenStub().bounds)
        case "visibleFrame": return .native(ScreenStub().visibleFrame)
        case "frame": return .native(ScreenStub().frame)
        default: return nil
        }
    }
    if value is MainQueueStub {
        if name == "asyncAfter" {
            // ZERO-delay deadlines deliver on the next drain. Positive
            // delays stay inert in trace mode (deterministic probes must not
            // grow timers), but the real SwiftUI registry schedules them so
            // interactive code can debounce user input.
            return .hostFunction(HostFunction(name: "asyncAfter") { args, ctx in
                // `asyncAfter(deadline:execute:)` passes the work LABELED —
                // and often as a closure VALUE (`execute: routeToDestination`),
                // not a literal.
                guard let closure = args.closure(labeled: "execute")
                    ?? args.firstUnlabeledClosure
                    ?? args.arguments.compactMap({ $0.value.closureValue }).last else { return .void }
                let deadline = args.labeled("deadline")
                let delay = deadline.flatMap { value -> Double? in
                    if let d = value.doubleValue { return d }
                    if case .host(let any) = value, let chain = any as? ChainedImplicitCall {
                        _ = chain
                        return 0
                    }
                    return nil
                } ?? 0
                let action = ActionValue(run: {
                    _ = try? ctx.callClosure(closure, arguments: [])
                })
                if delay > 0.001 {
                    if MainQueueDrain.schedulesRealTimers {
                        Task { @MainActor in
                            try? await Task.sleep(
                                nanoseconds: UInt64(max(0, delay) * 1_000_000_000)
                            )
                            action.run()
                        }
                        return .void
                    }
                    // Trace mode: BOUNDED delays deliver on the next drain,
                    // once per drain (URLProtocol mocks ship loadingTime:
                    // 0.1 — the await in the test spans it on device).
                    // Far-future timers stay inert: no probe frame would
                    // ever contain them.
                    if delay <= 30 {
                        MainQueueDrain.delayedPending.append(action)
                        Task { @MainActor in MainQueueDrain.drain() }
                    }
                    return .void
                }
                MainQueueDrain.pending.append(action)
                Task { @MainActor in MainQueueDrain.drain() }
                return .void
            })
        }
        if name == "async" {
            return .hostFunction(HostFunction(name: "async") { args, ctx in
                guard let closure = args.firstUnlabeledClosure else { return .void }
                // A main-actor Task hop matches DispatchQueue.main.async
                // semantics and, unlike raw GCD, also drains under swift test.
                let action = ActionValue(run: {
                    do {
                        _ = try ctx.callClosure(closure, arguments: [])
                    } catch {
                        // Deliveries swallow errors like GCD would crash-
                        // free harnesses; the trace surfaces them.
                        if LiveCheckSupport.traceLifecycle {
                            print("   ⚠ main.async delivery threw: \(error)")
                        }
                    }
                })
                MainQueueDrain.pending.append(action)
                Task { @MainActor in MainQueueDrain.drain() }
                return .void
            })
        }
        return nil
    }
    if let proxy = value as? GeometryProxy {
        switch name {
        case "size": return .native(proxy.size)
        case "safeAreaInsets": return .native(proxy.safeAreaInsets)
        case "frame":
            return .hostFunction(HostFunction(name: "frame") { args, _ in
                .native(proxy.frame(in: try coordinateSpace(args.labeled("in") ?? args.positional(0))))
            })
        case "bounds":
            return .hostFunction(HostFunction(name: "bounds") { args, _ in
                guard let space = namedCoordinateSpace(args.labeled("of") ?? args.positional(0)),
                      let rect = proxy.bounds(of: space) else {
                    return .none(wrappedTypeName: "CGRect")
                }
                return .some(.native(rect), wrappedTypeName: "CGRect")
            })
        default: return nil
        }
    }
    if let stub = value as? GeometryProxyStub {
        switch name {
        case "size": return .native(stub.size)
        case "safeAreaInsets": return .native(EdgeInsets())
        case "frame":
            return .hostFunction(HostFunction(name: "frame") { _, _ in
                .native(CGRect(origin: .zero, size: stub.size))
            })
        case "bounds":
            return .hostFunction(HostFunction(name: "bounds") { _, _ in
                .native(CGRect(origin: .zero, size: stub.size))
            })
        default: return nil
        }
    }
    if let proxy = value as? ScrollViewProxy {
        if name == "scrollTo" {
            return .hostFunction(HostFunction(name: "scrollTo") { args, _ in
                guard let id = args.positional(0) else { return .void }
                let anchor = (try? args.labeled("anchor").map(Coerce.unitPoint)) ?? nil
                proxy.scrollTo(id.stringValue ?? id.stringified, anchor: anchor)
                return .void
            })
        }
        return nil
    }
    if value is ScrollViewProxyStub {
        if name == "scrollTo" {
            return .hostFunction(HostFunction(name: "scrollTo") { _, _ in .void })
        }
        return nil
    }
    if value is MapProxyStub {
        if name == "convert" {
            return .hostFunction(HostFunction(name: "convert") { _, _ in
                .none(wrappedTypeName: "CLLocationCoordinate2D")
            })
        }
        return nil
    }
    if value is GraphicsContextStub {
        // Every draw command is accepted and ignored — fill/stroke/
        // translateBy… execute inertly with no surface.
        return .hostFunction(HostFunction(name: name) { _, _ in .void })
    }
    if let stub = value as? PathDrawStub {
        return .hostFunction(HostFunction(name: name) { args, _ in
            stub.apply(name, args)
            return .native(stub) // chainable: Path{}.strokedPath(...).fill(...)
        })
    }
    if let context = value as? TimelineViewDefaultContext {
        if name == "date" { return .native(context.date) }
        return nil
    }
    if let stub = value as? TimelineContextStub {
        if name == "date" { return .native(stub.date) }
        return nil
    }
    if let size = value as? CGSize {
        switch name {
        case "width": return .native(Double(size.width))
        case "height": return .native(Double(size.height))
        default: return nil
        }
    }
    if let rect = value as? CGRect {
        switch name {
        case "minX": return .native(Double(rect.minX))
        case "minY": return .native(Double(rect.minY))
        case "midX": return .native(Double(rect.midX))
        case "midY": return .native(Double(rect.midY))
        case "maxX": return .native(Double(rect.maxX))
        case "maxY": return .native(Double(rect.maxY))
        case "width": return .native(Double(rect.width))
        case "height": return .native(Double(rect.height))
        case "size": return .native(rect.size)
        case "origin": return .native(rect.origin)
        default: return nil
        }
    }
    if let point = value as? CGPoint {
        switch name {
        case "x": return .native(Double(point.x))
        case "y": return .native(Double(point.y))
        default: return nil
        }
    }
    return nil
}

func bridgeHostProperty(_ name: String, on value: Any) -> HostProperty? {
    hostObjectProperty(name, on: value)
}

/// `.global` / `.local` / `.named("x")` / `.scrollView(axis:)` in frame(in:).
private func coordinateSpace(_ value: RuntimeValue?) throws -> some CoordinateSpaceProtocol {
    guard let value else { return AnyCoordinateSpaceBox(.global) }
    if case .implicitMember(let name) = value {
        switch name {
        case "global": return AnyCoordinateSpaceBox(.global)
        case "local": return AnyCoordinateSpaceBox(.local)
        case "scrollView": return AnyCoordinateSpaceBox(.scrollView)
        default: break
        }
    }
    if case .host(let any) = value, let call = any as? ImplicitMemberCall {
        switch call.name {
        case "named":
            if let name = call.arguments.positional(0)?.stringValue {
                return AnyCoordinateSpaceBox(.named(name))
            }
        case "scrollView":
            if case .implicitMember(let axisName)? = call.arguments.labeled("axis") {
                return AnyCoordinateSpaceBox(.scrollView(axis: axisName == "horizontal" ? .horizontal : .vertical))
            }
            return AnyCoordinateSpaceBox(.scrollView)
        default: break
        }
    }
    return AnyCoordinateSpaceBox(.global)
}

/// `bounds(of:)` takes a NamedCoordinateSpace specifically.
private func namedCoordinateSpace(_ value: RuntimeValue?) -> NamedCoordinateSpace? {
    guard let value else { return nil }
    if case .implicitMember("scrollView") = value { return .scrollView }
    if case .host(let any) = value, let call = any as? ImplicitMemberCall {
        switch call.name {
        case "named":
            if let name = call.arguments.positional(0)?.stringValue { return .named(name) }
        case "scrollView":
            if case .implicitMember(let axisName)? = call.arguments.labeled("axis") {
                return .scrollView(axis: axisName == "horizontal" ? .horizontal : .vertical)
            }
            return .scrollView
        default: break
        }
    }
    return nil
}

/// Type-erases the heterogeneous coordinate-space statics behind one type.
private struct AnyCoordinateSpaceBox: CoordinateSpaceProtocol {
    let space: CoordinateSpace

    init(_ proto: some CoordinateSpaceProtocol) {
        self.space = proto.coordinateSpace
    }

    var coordinateSpace: CoordinateSpace { space }
}

extension ViewRegistry {
    public func hostProperty(named name: String, on value: Any) -> HostProperty? {
        bridgeHostProperty(name, on: value)
    }

    public func hostMember(_ name: String, on value: Any) -> RuntimeValue? {
        bridgeHostMember(name, on: value)
    }

    public func hostMethod(_ name: String, on value: Any) -> RuntimeValue? {
        GeneratedMembers.method(name, on: value)
    }

    public func hostProtocolCandidates(of value: Any) -> [String] {
        bridgeHostProtocolCandidates(of: value)
    }

    public func hostTypeName(of value: Any) -> String? {
        bridgeHostTypeName(of: value)
    }

    public func hostMutatedCopy(settingMember name: String, on value: Any, to newValue: RuntimeValue) -> Any? {
        bridgeHostMutatedCopy(settingMember: name, on: value, to: newValue)
    }

    /// `Text("a") + Text("b")` — both sides are AnyView-erased by the time
    /// they meet, so concatenation approximates as an adjacent zero-spacing
    /// HStack (documented divergence: no line-wrap continuity).
    public func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue? {
        // DynamicTypeSize markers order by the REAL case ladder
        // (WidthThresholdReader's `dynamicType >= .xxLarge`).
        if ["<", "<=", ">", ">=", "==", "!="].contains(op),
           case .implicitMember(let leftName) = lhs,
           case .implicitMember(let rightName) = rhs,
           let leftIndex = Self.dynamicTypeSizeOrder.firstIndex(of: leftName),
           let rightIndex = Self.dynamicTypeSizeOrder.firstIndex(of: rightName) {
            switch op {
            case "<": return .bool(leftIndex < rightIndex)
            case "<=": return .bool(leftIndex <= rightIndex)
            case ">": return .bool(leftIndex > rightIndex)
            case ">=": return .bool(leftIndex >= rightIndex)
            case "==": return .bool(leftIndex == rightIndex)
            default: return .bool(leftIndex != rightIndex)
            }
        }
        guard op == "+", isViewValue(lhs), isViewValue(rhs),
              let left = try? Self.anyView(lhs), let right = try? Self.anyView(rhs) else { return nil }
        return .native(AnyView(HStack(spacing: 0) {
            left
            right
        }))
    }

    static let dynamicTypeSizeOrder = [
        "xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge",
        "accessibility1", "accessibility2", "accessibility3", "accessibility4",
        "accessibility5",
    ]

    func registerGeometryViews() {
        constructors["GeometryReader"] = HostFunction(name: "GeometryReader") { args, ctx in
            guard let content = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "GeometryReader needs a content closure")
            }
            return .native(AnyView(GeometryReader { proxy in
                renderProxyContent(content, argument: .native(proxy), ctx: ctx, in: "GeometryReader")
            }))
        }

        // Real-side Canvas renders its area with the interpreted renderer run
        // once against an inert context (documented divergence: draw commands
        // don't reach the real GraphicsContext — the closure's state math
        // still executes, the surface stays empty).
        constructors["Canvas"] = HostFunction(name: "Canvas") { args, ctx in
            if let renderer = args.firstUnlabeledClosure {
                _ = try ctx.callClosure(renderer, arguments: [
                    .native(GraphicsContextStub()),
                    .native(CGSize(width: 390, height: 844)),
                ])
            }
            return .native(AnyView(Canvas { _, _ in }))
        }

        constructors["Path"] = HostFunction(name: "Path") { args, ctx in
            let path = PathDrawStub()
            if let builder = args.firstUnlabeledClosure {
                _ = try ctx.callClosure(builder, arguments: [.native(path)])
            }
            return .native(path)
        }

        constructors["ScrollViewReader"] = HostFunction(name: "ScrollViewReader") { args, ctx in
            guard let content = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "ScrollViewReader needs a content closure")
            }
            return .native(AnyView(ScrollViewReader { proxy in
                renderProxyContent(content, argument: .native(proxy), ctx: ctx, in: "ScrollViewReader")
            }))
        }

        constructors["TimelineView"] = HostFunction(name: "TimelineView") { args, ctx in
            guard let content = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "TimelineView needs a content closure")
            }
            // Schedules beyond .animation collapse to it — honest enough for
            // interpreted animations that read context.date.
            return .native(AnyView(TimelineView(.animation) { context in
                renderProxyContent(content, argument: .native(context), ctx: ctx, in: "TimelineView")
            }))
        }
    }
}

/// Evaluate interpreted content with a layout-time argument; errors surface
/// via RenderDiagnostics and render as an empty view (SwiftUI can't rethrow).
private func renderProxyContent(
    _ content: ClosureValue,
    argument: RuntimeValue,
    ctx: EvalContext,
    in container: String
) -> AnyView {
    do {
        let views = try ctx.callBuilderClosure(content, arguments: [argument])
            .map(ViewRegistry.anyView)
        return views.count == 1 ? views[0] : AnyView(ZStack(alignment: .topLeading) { ViewRegistry.indexed(views) })
    } catch let error as RuntimeError {
        RenderDiagnostics.record(error, in: container)
        return AnyView(EmptyView())
    } catch {
        RenderDiagnostics.record(RuntimeError(message: String(describing: error)), in: container)
        return AnyView(EmptyView())
    }
}


/// CG value-type member writes: mutate a copy, hand it back for the
/// lvalue write-through (`size.width = 300`, `rect.origin.y = 10`).
func bridgeHostMutatedCopy(settingMember name: String, on value: Any, to newValue: RuntimeValue) -> Any? {
    if var size = value as? CGSize {
        guard let amount = newValue.doubleValue else { return nil }
        switch name {
        case "width": size.width = amount
        case "height": size.height = amount
        default: return nil
        }
        return size
    }
    if var point = value as? CGPoint {
        guard let amount = newValue.doubleValue else { return nil }
        switch name {
        case "x": point.x = amount
        case "y": point.y = amount
        default: return nil
        }
        return point
    }
    if var rect = value as? CGRect {
        switch name {
        case "origin":
            if case .host(let any) = newValue, let origin = any as? CGPoint {
                rect.origin = origin
                return rect
            }
        case "size":
            if case .host(let any) = newValue, let size = any as? CGSize {
                rect.size = size
                return rect
            }
        default:
            return nil
        }
        return nil
    }
    return nil
}

/// Stub → host type names, so user `extension UIApplication { … }` members
/// dispatch on the stubs standing in for those objects.
/// PROTOCOL umbrellas host values conform to — user protocol extensions
/// (`extension Cancellable { func store(in:) }`) dispatch through these.
func bridgeHostProtocolCandidates(of value: Any) -> [String] {
    switch value {
    case is RuntimeTaskHandle: return ["Task", "Cancellable"]
    case is AnyCancellableBox: return ["AnyCancellable", "Cancellable"]
    case is PassthroughSubjectBox: return ["PassthroughSubject", "Publisher"]
    case let stub as UIKitStub: return stub.roles
    default: return []
    }
}

func bridgeHostTypeName(of value: Any) -> String? {
    switch value {
    case is RuntimeTaskHandle: return "Task"
    case is AppStub: return "UIApplication"
    case is ResultBox: return "Result"
    case is CurrentValueSubjectBox: return "CurrentValueSubject"
    case is BundleBox: return "Bundle"
    case is WindowStub: return "UIWindow"
    case is WindowSceneStub: return "UIWindowScene"
    case is ScreenStub: return "UIScreen"
    case is Color: return "Color"
    case is CalendarBox: return "Calendar"
    case is ProcessInfoBox: return "ProcessInfo"
    case is UIImageBox: return "UIImage"
    case is FileManagerBox: return "FileManager"
    case is Locale: return "Locale"
    case is DateFormatterBox: return "DateFormatter"
    case is NumberFormatterBox: return "NumberFormatter"
    case is DateComponentsBox: return "DateComponents"
    default: return nil
    }
}
