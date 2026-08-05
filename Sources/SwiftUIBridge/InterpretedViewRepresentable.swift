#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI
import SwiftInterpreter

// Interpreted view-representable conformances EXECUTE, the same way the
// controller-representable sibling does: the real SwiftUI lifecycle drives
// the interpreted makeCoordinator/make/update methods, and the platform view
// the interpreted body CONSTRUCTS is adopted as the represented view.
//
// A representable is a CONFORMANCE the app declares and the framework
// consumes, so the bridge builds the witness rather than recognizing a type:
// nothing here names an app or SDK representable, only the protocol's own
// method shape. Protocol witnesses are interface-inexpressible (the
// InterpretedView / InterpretedShape / InterpretedLayout genre in AGENTS.md).

/// The platform view a representable represents, under whichever UI framework
/// this build hosts through.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
typealias InterpretedRepresentedView = NSView
#elseif canImport(UIKit)
typealias InterpretedRepresentedView = UIView
#endif

#if (canImport(AppKit) && !targetEnvironment(macCatalyst)) || canImport(UIKit)

/// Recovers the real platform view an interpreted expression produced —
/// either a bare host reference or one carried by the generated platform
/// tier. Shared with `InterpretedHostController`, whose `loadView` adopts a
/// view the interpreted code stored rather than returned.
func interpretedRepresentedView(_ value: RuntimeValue?) -> InterpretedRepresentedView? {
    guard let value, case .host(let any) = value else { return nil }
    if let view = any as? InterpretedRepresentedView { return view }
    if let platform = any as? GeneratedPlatformValue,
       let view = platform.payload as? InterpretedRepresentedView {
        return view
    }
    return nil
}

/// Carries the interpreted `Coordinator` across the representable's lifecycle,
/// plus the runtime value `make` returned. The MADE VALUE is handed back to
/// `update` verbatim rather than re-wrapped, so the view's identity and any
/// configuration the interpreted code stored on it survive the round trip.
final class InterpretedRepresentableCoordinator {
    var interpretedCoordinator: RuntimeValue?
    var madeValue: RuntimeValue?
}

/// The interpreted witness for `NSViewRepresentable` / `UIViewRepresentable`.
/// Method names differ per platform but the lifecycle does not, so the
/// execution core is written once and the conformance below only supplies the
/// framework's spelling.
struct InterpretedViewRepresentable {
    let instance: Instance
    let interpreter: Interpreter

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    static let makeMethod = "makeNSView"
    static let updateMethod = "updateNSView"
    static let contextRole = "NSViewRepresentableContext"
#else
    static let makeMethod = "makeUIView"
    static let updateMethod = "updateUIView"
    static let contextRole = "UIViewRepresentableContext"
#endif

    /// nil unless the interpreted symbol actually implements THIS platform's
    /// view shape — a representable written only against the other framework
    /// keeps the documented inert degrade (the Lottie precedent).
    static func hosting(
        instance: Instance, interpreter: Interpreter
    ) -> InterpretedViewRepresentable? {
        guard instance.symbol.methods[makeMethod] != nil else { return nil }
        return InterpretedViewRepresentable(
            instance: instance, interpreter: interpreter)
    }

    /// `context` is a configurable bag rather than an inert stub because the
    /// coordinator reaches the interpreted body THROUGH it
    /// (`context.coordinator.hostingController`); a stored write on a
    /// `UIKitStub` is exactly the round-trip that read needs.
    private func contextBag(
        _ coordinator: InterpretedRepresentableCoordinator
    ) -> RuntimeValue {
        let bag = UIKitStub(roles: [Self.contextRole])
        if let interpreted = coordinator.interpretedCoordinator {
            bag.config["coordinator"] = interpreted
        }
        return .native(bag)
    }

    func makeInterpretedCoordinator() -> InterpretedRepresentableCoordinator {
        let coordinator = InterpretedRepresentableCoordinator()
        // `makeCoordinator` is optional in the protocol — its absence is a
        // representable that needs no coordinator, not a failure.
        guard instance.symbol.methods["makeCoordinator"] != nil else {
            return coordinator
        }
        do {
            coordinator.interpretedCoordinator = try interpreter.callMethod(
                named: "makeCoordinator", on: instance, arguments: [])
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: "representable makeCoordinator failed: \(error)"),
                in: instance.symbol.name)
        }
        return coordinator
    }

    func makeInterpretedView(
        _ coordinator: InterpretedRepresentableCoordinator
    ) -> InterpretedRepresentedView {
        do {
            let made = try interpreter.callMethodLabeled(
                named: Self.makeMethod, on: instance,
                arguments: [(label: "context", value: contextBag(coordinator))])
            guard let view = interpretedRepresentedView(made) else {
                throw RuntimeError(message:
                    "\(Self.makeMethod) returned \(made.stringified), not a view")
            }
            coordinator.madeValue = made
            return view
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: "representable make failed: \(error)"),
                in: instance.symbol.name)
            return InterpretedRepresentedView()
        }
    }

    func updateInterpretedView(
        _ coordinator: InterpretedRepresentableCoordinator
    ) {
        guard instance.symbol.methods[Self.updateMethod] != nil,
              let made = coordinator.madeValue else { return }
        do {
            _ = try interpreter.callMethodLabeled(
                named: Self.updateMethod, on: instance,
                arguments: [
                    (label: nil, value: made),
                    (label: "context", value: contextBag(coordinator)),
                ])
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: "representable update failed: \(error)"),
                in: instance.symbol.name)
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension InterpretedViewRepresentable: NSViewRepresentable {
    func makeCoordinator() -> InterpretedRepresentableCoordinator {
        makeInterpretedCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        makeInterpretedView(context.coordinator)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateInterpretedView(context.coordinator)
    }
}
#elseif canImport(UIKit)
extension InterpretedViewRepresentable: UIViewRepresentable {
    func makeCoordinator() -> InterpretedRepresentableCoordinator {
        makeInterpretedCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        makeInterpretedView(context.coordinator)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        updateInterpretedView(context.coordinator)
    }
}
#endif

#endif
