import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck R2 card-chrome class: CardNavigationHeader blanked because
/// `.labelStyle(.cardNavigationHeader)` was unregistered (the subtree
/// absorbed); card fills read 12/255 dark because `#if canImport(UIKit)`
/// held on the macOS canvas and the hierarchical style chain
/// `.quaternary.opacity(0.5)` threw out of the style funnel.
@Suite struct InterpretedStyleTests {
    // A custom LabelStyle conformer resolved from a protocol-extension
    // static runs its interpreted makeBody with configuration.title/.icon.
    @MainActor
    @Test func customLabelStyleRunsInterpretedMakeBody() throws {
        let source = """
        struct MarkerLabelStyle: LabelStyle {
            func makeBody(configuration: Configuration) -> some View {
                VStack(spacing: 0) {
                    configuration.title
                    Rectangle().fill(Color.black).frame(width: 120, height: 40)
                }
            }
        }

        extension LabelStyle where Self == MarkerLabelStyle {
            static var marker: MarkerLabelStyle {
                MarkerLabelStyle()
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Label(String("T"), systemImage: String("circle"))
                        .labelStyle(.marker)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 200, height: 200))
        // makeBody's black marker rectangle paints at the center-bottom of
        // the stacked label; the unstyled Label (or a blank absorb) has no
        // black anywhere near the center.
        var sawBlack = false
        for y in 90..<140 where !sawBlack {
            for x in 80..<120 {
                if let color = rep.colorAt(x: x, y: y), color.redComponent < 0.2 {
                    sawBlack = true
                    break
                }
            }
        }
        #expect(sawBlack, "custom LabelStyle makeBody did not render its marker")
    }

    // `.quaternary.opacity(0.5)` — a hierarchical base through a style
    // chain must keep the REAL style (the FoodTruck card-tile fill), not
    // throw out of the funnel into a flat-gray stand-in.
    @MainActor
    @Test func hierarchicalStyleChainKeepsRealStyle() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Rectangle()
                        .fill(.quaternary.opacity(0.5))
                        .frame(width: 200, height: 200)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 200, height: 200))
        guard let color = rep.colorAt(x: 100, y: 100) else {
            Issue.record("no pixel")
            return
        }
        // Native .quaternary.opacity(0.5) on aqua/white reads ~242/255; the
        // old flat-gray fallback read ~230. Band, not exact, so OS-version
        // appearance drift doesn't flake the pin.
        let value = color.redComponent * 255
        #expect(value > 236 && value < 252,
                "hierarchical chain fill reads \(value), expected the ~242 native band")
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
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }
}

/// canImport under a platform identity: the compiled macOS app has no
/// UIKit, so `#if canImport(UIKit)` must take #else there — and the iOS
/// canvas has no AppKit (FoodTruck's card fill took the UIKit branch on
/// macOS and rendered the wrong gray).
@Suite struct PlatformCanImportTests {
    @MainActor
    @Test func canImportFollowsPlatformIdentity() throws {
        let source = """
        #if canImport(UIKit)
        let kit = "uikit"
        #else
        let kit = "appkit"
        #endif
        #if canImport(AppKit)
        let desk = "appkit"
        #else
        let desk = "uikit"
        #endif
        """
        let previous = Interpreter.interpretsAsPlatform
        defer { Interpreter.interpretsAsPlatform = previous }

        Interpreter.interpretsAsPlatform = "macOS"
        let mac = Interpreter(registry: TraceRegistry())
        try mac.run(source: source)
        #expect(mac.globals.lookup("kit")?.stringValue == "appkit")
        #expect(mac.globals.lookup("desk")?.stringValue == "appkit")

        Interpreter.interpretsAsPlatform = "iOS"
        let phone = Interpreter(registry: TraceRegistry())
        try phone.run(source: source)
        #expect(phone.globals.lookup("kit")?.stringValue == "uikit")
        #expect(phone.globals.lookup("desk")?.stringValue == "uikit")
    }
}
