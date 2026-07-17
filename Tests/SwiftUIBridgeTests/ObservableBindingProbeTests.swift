import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct ObservableBindingProbe {
    @MainActor
    @Test func projectedModelPropertyBinding() throws {
        let source = """
        class Model: ObservableObject {
            @Published var name: String = "Alpha"
        }

        struct Editor: View {
            @Binding var name: String
            var body: some View {
                VStack {
                    Text(String("EDITOR:") + name)
                    TextField(String("Name"), text: $name)
                }
            }
        }

        @main
        struct P: App {
            @StateObject private var model = Model()
            var body: some Scene {
                WindowGroup {
                    Editor(name: $model.name)
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
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE observable-binding ink:", ink, "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(5) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(100))")
        }
        #expect(ink > 100)
    }

    @MainActor
    static func bitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("no rep")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    @MainActor
    @Test func hSplitViewRendersBothPanes() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    HSplitView {
                        Text(String("LEFT PANE")).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(String("RIGHT PANE")).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE hsplit ink:", ink, "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(3) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(100))")
        }
        #expect(ink > 100)
    }

    @MainActor
    @Test func structBindingThroughModelRendersEditor() throws {
        let source = """
        struct Donut {
            var name: String = "Sprinkles"
        }

        class Model: ObservableObject {
            @Published var newDonut = Donut()
        }

        struct Editor: View {
            @Binding var donut: Donut
            var body: some View {
                HSplitView {
                    Text(String("VIEW:") + donut.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Form {
                        TextField(String("Name"), text: $donut.name)
                    }
                }
            }
        }

        @main
        struct P: App {
            @StateObject private var model = Model()
            var body: some Scene {
                WindowGroup {
                    Editor(donut: $model.newDonut)
                        .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE struct-binding ink:", ink, "diags:", RenderDiagnostics.errors.count)
        for e in RenderDiagnostics.errors.prefix(3) {
            print("PROBE-DIAG \(e.view): \(e.error.message.prefix(100))")
        }
        #expect(ink > 100)
    }

    @MainActor
    @Test func harnessControlPlainText() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Text(String("HELLO CONTROL"))
                        .background(Color.white)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE harness-control ink:", ink)
        #expect(ink > 100)
    }

    @MainActor
    @Test func plainModelPropertyRead() throws {
        let source = """
        class Model: ObservableObject {
            @Published var name: String = "Alpha"
        }

        @main
        struct P: App {
            @StateObject private var model = Model()
            var body: some Scene {
                WindowGroup {
                    Text(String("NAME:") + model.name)
                        .background(Color.white)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 300, height: 120))
        var ink = 0
        for x in 0..<300 { for y in 0..<120 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.9 { ink += 1 }
        } }
        print("PROBE plain-model-read ink:", ink, "diags:", RenderDiagnostics.errors.count)
        #expect(ink > 100)
    }
}
