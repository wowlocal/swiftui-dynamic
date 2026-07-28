#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import SwiftInterpreter

// Interpreted NSViewControllerRepresentable conformances EXECUTE: the real
// SwiftUI lifecycle drives the interpreted make/update methods, and a real
// NSViewController host runs the interpreted controller subclass's loadView.
// Protocol witnesses are interface-inexpressible (the InterpretedView /
// InterpretedShape / InterpretedLayout genre in AGENTS.md); everything the
// interpreted body CONSTRUCTS flows through the generated platform tier.

struct InterpretedControllerRepresentable: NSViewControllerRepresentable {
    let instance: Instance
    let interpreter: Interpreter

    /// nil unless the interpreted symbol actually implements the macOS
    /// controller shape — UIKit-only representables keep the documented
    /// inert degrade (the Lottie precedent).
    static func hosting(
        instance: Instance, interpreter: Interpreter
    ) -> InterpretedControllerRepresentable? {
        guard instance.symbol.methods["makeNSViewController"] != nil else {
            return nil
        }
        return InterpretedControllerRepresentable(
            instance: instance, interpreter: interpreter)
    }

    private var contextBag: RuntimeValue {
        .native(UIKitStub(roles: ["NSViewControllerRepresentableContext"]))
    }

    func makeNSViewController(context: Context) -> InterpretedHostController {
        let host = InterpretedHostController()
        host.interpreter = interpreter
        do {
            let made = try interpreter.callMethodLabeled(
                named: "makeNSViewController", on: instance,
                arguments: [(label: "context", value: contextBag)])
            guard case .instance(let controller) = made else {
                throw RuntimeError(message:
                    "makeNSViewController returned \(made.stringified), not a controller instance")
            }
            host.interpreted = controller
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: "representable make failed: \(error)"),
                in: instance.symbol.name)
        }
        return host
    }

    func updateNSViewController(
        _ controller: InterpretedHostController, context: Context
    ) {
        guard let interpreted = controller.interpreted else { return }
        // Force the view hierarchy first — native semantics: the SwiftUI
        // host loads the controller's view before the first update.
        _ = controller.view
        do {
            _ = try interpreter.callMethodLabeled(
                named: "updateNSViewController", on: instance,
                arguments: [
                    (label: nil, value: .instance(interpreted)),
                    (label: "context", value: contextBag),
                ])
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: "representable update failed: \(error)"),
                in: instance.symbol.name)
        }
    }
}

/// The real AppKit controller whose lifecycle delegates to the interpreted
/// controller-subclass instance. The interpreted `view` property IS the
/// bridge: loadView runs the interpreted override, then adopts whatever
/// real NSView the interpreted code stored there.
final class InterpretedHostController: NSViewController {
    var interpreted: Instance?
    var interpreter: Interpreter?

    override func loadView() {
        guard let interpreted, let interpreter,
              interpreted.symbol.methods["loadView"] != nil else {
            view = NSView()
            return
        }
        do {
            _ = try interpreter.callMethod(
                named: "loadView", on: interpreted, arguments: [])
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: "loadView failed: \(error)"),
                in: interpreted.symbol.name)
        }
        view = Self.unwrapView(interpreted.box(for: "view")?.value) ?? NSView()
    }

    static func unwrapView(_ value: RuntimeValue?) -> NSView? {
        guard let value else { return nil }
        if case .host(let any) = value {
            if let view = any as? NSView { return view }
            if let platform = any as? GeneratedPlatformValue,
               let view = platform.payload as? NSView {
                return view
            }
        }
        return nil
    }
}
#endif
