import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// PARITY probes for binding-write propagation (2026-07-18 finding): the
// offscreen borderless-window harness does NOT deliver binding-write
// re-renders even for PURE NATIVE SwiftUI (a field's sendAction commits
// its own text, but sibling observers of the same model stay stale until
// a real event-loop turn). The honest pin is therefore interpreted ==
// native under the identical harness — if either side's behavior changes,
// the parity expectation catches it. The live rename-retitle question
// (R4's reported-only titled= metric) needs a live-twin comparison and
// stays open.
@Suite struct BindingWritePropagationParity {
    private final class NativeModel: ObservableObject {
        @Published var name = "Alpha"
    }
    private struct NativeEditor: View {
        @ObservedObject var model: NativeModel
        var body: some View { TextField("Name", text: $model.name) }
    }
    private struct NativeWitness: View {
        @ObservedObject var model: NativeModel
        var body: some View { TextField("Witness", text: $model.name) }
    }
    private struct NativeRoot: View {
        @StateObject var model = NativeModel()
        var body: some View {
            VStack { NativeEditor(model: model); NativeWitness(model: model) }
                .background(Color.white)
        }
    }

    @MainActor
    private func driveAndReadWitness(_ view: AnyView) -> String? {
        let size = NSSize(width: 320, height: 120)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = hosting
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        func allFields(_ view: NSView) -> [NSTextField] {
            var result: [NSTextField] = []
            if let field = view as? NSTextField, field.isEditable { result.append(field) }
            for sub in view.subviews { result += allFields(sub) }
            return result
        }
        let fields = allFields(hosting)
        guard fields.count == 2 else { return nil }
        fields[0].stringValue = "Alpha X"
        _ = fields[0].sendAction(fields[0].action, to: fields[0].target)
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        return allFields(hosting).last?.stringValue
    }

    @MainActor
    @Test func publishedFieldBindingWriteMatchesNativeHarnessBehavior() throws {
        let source = """
        class Model: ObservableObject {
            @Published var name: String = "Alpha"
        }

        struct Editor: View {
            @ObservedObject var model: Model
            var body: some View {
                TextField(String("Name"), text: $model.name)
            }
        }

        struct Witness: View {
            @ObservedObject var model: Model
            var body: some View {
                TextField(String("Witness"), text: $model.name)
            }
        }

        @main
        struct P: App {
            @StateObject private var model = Model()
            var body: some Scene {
                WindowGroup {
                    VStack {
                        Editor(model: model)
                        Witness(model: model)
                    }
                    .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed: \(rendered)")
            return
        }
        let interp = driveAndReadWitness(view)
        let native = driveAndReadWitness(AnyView(NativeRoot()))
        print("PROBE parity interp:", interp ?? "nil", "native:", native ?? "nil",
              "diags:", RenderDiagnostics.errors.count)
        #expect(interp != nil && native != nil)
        #expect(interp == native,
                "binding-write propagation diverged: interp '\(interp ?? "nil")' vs native '\(native ?? "nil")'")
        #expect(RenderDiagnostics.errors.isEmpty)
    }
}
