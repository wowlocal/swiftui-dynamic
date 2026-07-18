import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// Interpreted NSViewControllerRepresentable conformances execute: the shape
// mirrors FoodTruck's DetailedMapView (controller subclass with loadView
// building a real platform view, a guard-cast computed accessor, update
// driving configuration through it).
@Suite struct InterpretedRepresentableProbe {
    @MainActor
    @Test func controllerRepresentableLoadsAndConfiguresRealView() throws {
        let source = """
        import AppKit
        import SwiftUI

        struct ColorPane: NSViewControllerRepresentable {
            typealias ViewController = NSViewController

            class Controller: ViewController {
                var field: NSTextField {
                    guard let tempView = view as? NSTextField else {
                        fatalError("View could not be cast.")
                    }
                    return tempView
                }

                override func loadView() {
                    let field = NSTextField(labelWithString: String("UNSET"))
                    view = field
                }
            }

            func makeNSViewController(context: Context) -> Controller {
                Controller()
            }

            func updateNSViewController(_ controller: Controller, context: Context) {
                controller.field.stringValue = String("MAP CONTENT HERE")
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    ColorPane()
                        .frame(width: 260, height: 80)
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
        let rep = ObservableBindingProbe.bitmap(view, size: NSSize(width: 260, height: 80))
        var ink = 0
        for x in 0..<260 { for y in 0..<80 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.85 { ink += 1 }
        } }
        print("PROBE representable ink:", ink, "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(4) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(120))")
        }
        // The updated text painted through the REAL AppKit view — proof the
        // interpreted loadView ran, the view adopted, and update configured
        // it through the guard-cast accessor.
        #expect(ink > 150, "representable view content did not paint")
        #expect(RenderDiagnostics.errors.isEmpty)
    }
}
