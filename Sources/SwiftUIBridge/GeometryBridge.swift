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
            if case .native(let any)? = value { return any as? CGPoint }
            return nil
        }
        func rect(_ value: RuntimeValue?) -> CGRect? {
            if case .native(let any)? = value { return any as? CGRect }
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
                if case .native(let any) = result, let stub = any as? PathDrawStub {
                    return stub.path
                }
                if case .native(let any) = result, let real = any as? Path {
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

/// `DispatchQueue.main` — async dispatches through the real main queue.
struct MainQueueStub {}

/// Members on host-native values — shared by the real and trace registries
/// via their `hostMember` hooks. Numbers come back as Double so interpreted
/// arithmetic works on them.
func bridgeHostMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let member = hostObjectMember(name, on: value) {
        return member
    }
    if let marker = value as? HostTypeMarker {
        switch (marker.name, name) {
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
        case ("Double", "random"), ("CGFloat", "random"), ("Int", "random"):
            let wantsInt = marker.name == "Int"
            return .hostFunction(HostFunction(name: "random") { args, _ in
                guard let range = (args.labeled("in") ?? args.positional(0))?.rangeValue else {
                    throw RuntimeError(message: "random(in:) needs a range")
                }
                if wantsInt { return .native(Int.random(in: range)) }
                return .native(Double.random(in: Double(range.lowerBound)...Double(range.upperBound - 1)))
            })
        default:
            return nil
        }
    }
    if value is AppStub {
        switch name {
        case "windows": return .native([RuntimeValue.native(WindowStub())])
        case "connectedScenes": return .native([RuntimeValue.native(WindowSceneStub())])
        case "mainWindow", "keyWindow": return .native(WindowStub())
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
        if name == "async" {
            return .hostFunction(HostFunction(name: "async") { args, ctx in
                guard let closure = args.unlabeledClosures.first else { return .void }
                // A main-actor Task hop matches DispatchQueue.main.async
                // semantics and, unlike raw GCD, also drains under swift test.
                let action = ActionValue(run: { _ = try? ctx.callClosure(closure, arguments: []) })
                Task { @MainActor in action.run() }
                return .void
            })
        }
        if name == "asyncAfter" {
            return .hostFunction(HostFunction(name: "asyncAfter") { args, ctx in
                guard let closure = args.unlabeledClosures.first else { return .void }
                // `.now() + delay` arithmetic already reduced to seconds.
                let delay = (args.labeled("deadline") ?? args.labeled("wallDeadline"))?
                    .doubleValue ?? 0
                let action = ActionValue(run: { _ = try? ctx.callClosure(closure, arguments: []) })
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    action.run()
                }
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
                      let rect = proxy.bounds(of: space) else { return .nilValue }
                return .native(rect)
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
            return .hostFunction(HostFunction(name: "convert") { _, _ in .nilValue })
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
            return .void
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
    if case .native(let any) = value, let call = any as? ImplicitMemberCall {
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
    if case .native(let any) = value, let call = any as? ImplicitMemberCall {
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
    public func hostMember(_ name: String, on value: Any) -> RuntimeValue? {
        bridgeHostMember(name, on: value)
    }

    func registerGeometryViews() {
        constructors["GeometryReader"] = HostFunction(name: "GeometryReader") { args, ctx in
            guard let content = args.unlabeledClosures.first else {
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
            if let renderer = args.unlabeledClosures.first {
                _ = try ctx.callClosure(renderer, arguments: [
                    .native(GraphicsContextStub()),
                    .native(CGSize(width: 390, height: 844)),
                ])
            }
            return .native(AnyView(Canvas { _, _ in }))
        }

        constructors["Path"] = HostFunction(name: "Path") { args, ctx in
            let path = PathDrawStub()
            if let builder = args.unlabeledClosures.first {
                _ = try ctx.callClosure(builder, arguments: [.native(path)])
            }
            return .native(path)
        }

        constructors["ScrollViewReader"] = HostFunction(name: "ScrollViewReader") { args, ctx in
            guard let content = args.unlabeledClosures.first else {
                throw RuntimeError(message: "ScrollViewReader needs a content closure")
            }
            return .native(AnyView(ScrollViewReader { proxy in
                renderProxyContent(content, argument: .native(proxy), ctx: ctx, in: "ScrollViewReader")
            }))
        }

        constructors["TimelineView"] = HostFunction(name: "TimelineView") { args, ctx in
            guard let content = args.unlabeledClosures.first else {
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
