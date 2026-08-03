import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck R2 card-orders: custom `Layout` conformers must RUN their
/// interpreted sizeThatFits/placeSubviews (HeroSquareTilingLayout,
/// DiagonalDonutStackLayout), not fall back to a VStack flow. The direct
/// trailing-closure spelling (`MiniLayout { … }`) previously short-circuited
/// to groupViews before instantiation; ForEach children reach the layout as
/// one subview PER ELEMENT (native variadic expansion — verified natively:
/// AnyView does NOT block expansion, `AnyView(ForEach(0..<3))` presents 3
/// subviews to a Layout).
@Suite struct InterpretedLayoutTests {
    @MainActor
    @Test func directSpellingLayoutPlacesForEachChildrenDiagonally() throws {
        let source = """
        struct __PinLayout: Layout {
            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
                let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 90, height: 90))
                return CGSize(width: size.width, height: size.height)
            }
            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
                let cell = CGSize(width: 20, height: 20)
                let rect = CGRect(origin: CGPoint(x: bounds.minX, y: bounds.minY), size: cell)
                for index in subviews.indices {
                    let point = CGPoint(
                        x: rect.minX + Double(index) * 30,
                        y: rect.minY + Double(index) * 30
                    )
                    subviews[index].place(
                        at: point,
                        anchor: UnitPoint(x: 0, y: 0),
                        proposal: ProposedViewSize(width: cell.width, height: cell.height)
                    )
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    __PinLayout {
                        ForEach(0..<3) { _ in
                            Rectangle().fill(Color.black)
                        }
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

        let size = NSSize(width: 200, height: 200)
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
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            Issue.record("no bitmap")
            return
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        func luminance(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = rep.colorAt(x: x, y: y) else { return -1 }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        // The interpreted placeSubviews puts 20×20 black squares at
        // (0,0), (30,30), (60,60) — the same placement the compiled layout
        // produces. The VStack fallback would center-stack them instead.
        #expect(luminance(10, 10) < 0.3, "square 0 missing at (10,10)")
        #expect(luminance(40, 40) < 0.3, "square 1 missing at (40,40)")
        #expect(luminance(70, 70) < 0.3, "square 2 missing at (70,70)")
        #expect(luminance(10, 40) > 0.9, "off-diagonal should be white")
        #expect(luminance(150, 150) > 0.9, "beyond the diagonal should be white")
    }

    // The geometry the layout math relies on: CGRect(origin:size:) /
    // CGRect(x:y:width:height:) / UnitPoint(x:y:) constructions and CGRect
    // members flow through the interpreter as REAL host values.
    @Test func hostGeometryConstructorsEvaluate() throws {
        let source = """
        let rect = CGRect(origin: CGPoint(x: 5, y: 7), size: CGSize(width: 30, height: 40))
        let minX = rect.minX
        let maxY = rect.maxY
        let width = rect.width
        let flat = CGRect(x: 1, y: 2, width: 3, height: 4)
        let flatHeight = flat.height
        let anchor = UnitPoint(x: 1, y: 0.5)
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("minX")?.doubleValue == 5)
        #expect(interpreter.globals.lookup("maxY")?.doubleValue == 47)
        #expect(interpreter.globals.lookup("width")?.doubleValue == 30)
        #expect(interpreter.globals.lookup("flatHeight")?.doubleValue == 4)
        guard case .host(let any)? = interpreter.globals.lookup("anchor"),
              let unit = any as? UnitPoint else {
            Issue.record("UnitPoint(x:y:) did not evaluate to a host UnitPoint; got \(interpreter.globals.lookup("anchor")?.stringified ?? "nil")")
            return
        }
        #expect(unit.x == 1)
        #expect(unit.y == 0.5)
    }
}

/// An unbridged modifier must not make later collection children move into the
/// erased receiver's place. The modifier's pixels are unknowable, so the
/// fallback is deliberately invisible; its receiver-derived layout and hidden
/// separator are the reusable collection-composition contract.
@Suite struct UnbridgedModifierLayoutTests {
    /// An unbridged modifier must cost its receiver NOTHING: not the
    /// composition slot (erasing it moves FOOTER up into the missing row) and
    /// not the content (hiding it claims the row draws nothing, which is a
    /// statement about the receiver rather than about the unimplemented
    /// modifier). The expectation is the same List with the modifier simply
    /// not applied — identity is what an unapplied modifier means, and it is
    /// the only spelling here that a compiler could also produce.
    @MainActor
    @Test func erasedCollectionChildrenKeepLayoutAndContent() throws {
        let source = """
        List {
            Text("ROW A")
                .font(.title)
                .frame(height: 90)
                .fixtureUnbridgedModifier()
            Text("ROW B")
                .font(.title)
                .frame(height: 90)
                .fixtureUnbridgedModifier()
            Text("FOOTER")
        }
        .listStyle(.plain)
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("unbridged collection fixture failed: \(rendered)")
            return
        }
        #expect(RenderDiagnostics.errors.count == 2)

        let native = AnyView(
            List {
                Text("ROW A")
                    .font(.title)
                    .frame(height: 90)
                Text("ROW B")
                    .font(.title)
                    .frame(height: 90)
                Text("FOOTER")
            }
            .listStyle(.plain)
        )
        let size = NSSize(width: 260, height: 160)
        #expect(
            Self.mismatchedPixels(
                Self.bitmap(interpreted, size: size),
                Self.bitmap(native, size: size),
                size: size
            ) == 0
        )
    }

    /// Generated constructors and static members can now carry a concrete SDK
    /// View to this fallback. It must use the same semantic View predicate as
    /// ordinary rendering rather than an erasure-era list of wrapper types —
    /// the receiver is recognised as a view, so the chain is diagnosed rather
    /// than silently dropped.
    @MainActor
    @Test func concreteViewReceiverIsDiagnosedNotDropped() throws {
        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: """
            VStack {
                Color.red.fixtureUnbridgedModifier()
            }
            """,
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("concrete unbridged receiver failed: \(rendered)")
            return
        }

        _ = Self.bitmap(
            interpreted, size: NSSize(width: 40, height: 40))
        #expect(RenderDiagnostics.errors.count == 1)
    }

    private static func mismatchedPixels(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        var mismatched = 0
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
                where lhs.colorAt(x: x, y: y) != rhs.colorAt(x: x, y: y) {
                mismatched += 1
            }
        }
        return mismatched
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
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }
}

/// FoodTruck card tiles: `.strokeBorder(.quaternary, lineWidth: 0.5)` —
/// the REAL InsettableShape inside-stroke (retained at ShapeBox
/// construction; erasure loses the conformance and a centered stroke
/// reads visibly different under antialiasing at hairline widths).
@Suite struct StrokeBorderTests {
    @MainActor
    @Test func strokeBorderPaintsInsideStroke() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black, lineWidth: 8)
                        .frame(width: 60, height: 60)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        let size = NSSize(width: 100, height: 100)
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
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        func dark(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            return c.redComponent + c.greenComponent + c.blueComponent < 1.2
        }
        // Inside-stroke: ink INSIDE the 60×60 frame edge (frame spans
        // 20..80; an 8pt inside stroke inks ~21..28), none OUTSIDE it.
        #expect(dark(24, 50), "inside-stroke ink missing at x=24")
        #expect(!dark(17, 50), "ink leaked outside the shape edge")
        #expect(!dark(50, 50), "center should be unfilled")
    }
}
