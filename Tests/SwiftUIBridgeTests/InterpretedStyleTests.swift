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

    // Color-typed parameters must accept the same transformed Color values as
    // native Swift. FoodTruck's SocialFeedPostView uses this exact chain for
    // every donut shadow; rejecting it replaces each row with an error view.
    @MainActor
    @Test func opacityChainFeedsColorTypedModifier() throws {
        let chain = RuntimeValue.native(ChainedImplicitCall(
            base: .implicitMember("black"), member: "opacity",
            arguments: CallArguments(arguments: [
                .init(label: nil, value: .native(0.15)),
            ])))
        let resolved = try Coerce.color(chain).resolve(in: EnvironmentValues())
        #expect(Double(resolved.red) == 0)
        #expect(Double(resolved.green) == 0)
        #expect(Double(resolved.blue) == 0)
        #expect(abs(Double(resolved.opacity) - 0.15) < 0.000_001)

        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 80, height: 80)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
            }
        }
        """
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source, lazyTopLevelGlobals: true) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            _ = Self.bitmap(view, size: NSSize(width: 120, height: 120))
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    // Type-erased styles are values, not absorbing constructor bags. They
    // must survive an interpreted computed-property return and feed a
    // ShapeStyle-typed generated modifier.
    @MainActor
    @Test func anyShapeStyleRoundTripsThroughComputedProperty() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let erased = try interpreter.run(
            source: "AnyShapeStyle(.quaternary.opacity(0.5))")
        #expect(erased.hostPayload is AnyShapeStyle)

        let source = """
        struct StyledCircle: View {
            var style: AnyShapeStyle {
                AnyShapeStyle(.quaternary.opacity(0.5))
            }

            var body: some View {
                Circle()
                    .frame(width: 80, height: 80)
                    .backgroundStyle(style)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup { StyledCircle() }
            }
        }
        """
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source, lazyTopLevelGlobals: true) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            _ = Self.bitmap(view, size: NSSize(width: 120, height: 120))
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(viewName): \(error)")
            }
        }
    }

    // FoodTruck truck-row annotation class: palette symbols paint their
    // SECONDARY layer only when foregroundStyle(_:_:) dispatches through
    // the generated tier (arities 1-3). The old handwritten gateway read
    // just the first style, so `.foregroundStyle(.white, .indigo)`
    // rendered an all-white disc — no indigo anywhere on the canvas.
    @MainActor
    @Test func paletteSymbolPaintsSecondaryStyleLayer() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Image(systemName: String("moon.circle.fill"))
                        .imageScale(.large)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .indigo)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let rep = Self.bitmap(view, size: NSSize(width: 80, height: 80))
        var indigoPixels = 0
        for x in 0..<80 {
            for y in 0..<80 {
                if let color = rep.colorAt(x: x, y: y),
                   color.blueComponent > 0.5, color.redComponent < 0.55,
                   color.blueComponent - color.redComponent > 0.2 {
                    indigoPixels += 1
                }
            }
        }
        #expect(indigoPixels > 20)
    }

    // FoodTruck card-chrome class: `.continuous` corners are squircles.
    // The constructor used to drop `style:` and containerShape was inert,
    // so ContainerRelativeShape card fills rendered circular arcs —
    // L-bracket diffs at every card corner.
    @MainActor
    @Test func continuousCornersMatchNativeSquircles() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    VStack(spacing: 0) {
                        Text(String("card"))
                            .frame(width: 64, height: 44)
                            .background()
                            .clipShape(ContainerRelativeShape())
                    }
                    .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 80, height: 60)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            VStack(spacing: 0) {
                Text("card")
                    .frame(width: 64, height: 44)
                    .background()
                    .clipShape(ContainerRelativeShape())
            }
            .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        ), size: size)
        var mismatched = 0
        for x in 0..<80 {
            for y in 0..<60 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b,
                   abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        #expect(mismatched == 0)
    }

    // FoodTruck card-header class: in a STYLE position `.secondary` is
    // the HIERARCHICAL style deriving from the current primary — the
    // funnel used to hand back the concrete Color.secondary, so header
    // icons rendered gray instead of the accent-derived tint. The pin
    // compares against a compiled native control of the exact header
    // shape (icon .foregroundStyle(.secondary) under .foregroundColor(
    // .accentColor)).
    @MainActor
    @Test func hierarchicalSecondaryDerivesFromAccent() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    HStack(spacing: 4) {
                        Image(systemName: String("shippingbox"))
                            .foregroundStyle(.secondary)
                        Text(String("New Orders"))
                    }
                    .font(.headline)
                    .imageScale(.large)
                    .foregroundColor(.accentColor)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 160, height: 40)
        let interp = Self.bitmap(view, size: size)
        let native = Self.bitmap(AnyView(
            HStack(spacing: 4) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text("New Orders")
            }
            .font(.headline)
            .imageScale(.large)
            .foregroundColor(.accentColor)
        ), size: size)
        var mismatched = 0
        for x in 0..<160 {
            for y in 0..<40 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b,
                   abs(a.redComponent - b.redComponent) > 0.02
                    || abs(a.blueComponent - b.blueComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
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
