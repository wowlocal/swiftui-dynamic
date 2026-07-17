import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct BuilderLetProbeTests {
    @MainActor
    @Test func letBindingInBuilderAddsNoPhantomChild() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    VStack {
                        Rectangle().fill(Color.gray).frame(width: 40, height: 40)
                        VStack {
                            let title = String("The Classic")
                            Text(title)
                            HStack(spacing: 4) {
                                Image(systemName: String("face.smiling"))
                                Text(String("Savory"))
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                    }
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 160, height: 130)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            VStack {
                Rectangle().fill(Color.gray).frame(width: 40, height: 40)
                VStack {
                    let title = "The Classic"
                    Text(title)
                    HStack(spacing: 4) {
                        Image(systemName: "face.smiling")
                        Text("Savory")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
        ), size: size)
        var mismatched = 0
        for x in 0..<160 {
            for y in 0..<130 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE let-mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    @MainActor
    private static func bitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
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
}
