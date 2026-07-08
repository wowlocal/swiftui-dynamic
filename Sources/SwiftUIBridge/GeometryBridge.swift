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

/// iOS code reads `UIScreen.main.bounds`; the honest macOS analog is the main
/// screen's frame (fixed canvas headlessly).
struct ScreenStub {
    var bounds: CGRect {
        CGRect(origin: .zero, size: NSScreen.main?.frame.size ?? CGSize(width: 390, height: 844))
    }
}

/// `UIApplication.shared.windows.first?.safeAreaInsets…` — one window with
/// zero insets is the honest macOS analog.
struct AppStub {}
struct WindowStub {}

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
        default:
            return nil
        }
    }
    if value is AppStub {
        if name == "windows" { return .native([RuntimeValue.native(WindowStub())]) }
        return nil
    }
    if value is WindowStub {
        if name == "safeAreaInsets" { return .native(EdgeInsets()) }
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
        if name == "bounds" { return .native(ScreenStub().bounds) }
        return nil
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
        return nil
    }
    if let proxy = value as? GeometryProxy {
        switch name {
        case "size": return .native(proxy.size)
        case "frame":
            return .hostFunction(HostFunction(name: "frame") { args, _ in
                .native(proxy.frame(in: try coordinateSpace(args.labeled("in") ?? args.positional(0))))
            })
        default: return nil
        }
    }
    if let stub = value as? GeometryProxyStub {
        switch name {
        case "size": return .native(stub.size)
        case "frame":
            return .hostFunction(HostFunction(name: "frame") { _, _ in
                .native(CGRect(origin: .zero, size: stub.size))
            })
        default: return nil
        }
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
