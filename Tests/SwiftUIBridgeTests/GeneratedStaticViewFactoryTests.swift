import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A VIEW position supplies no contextual type, so an SDK static whose result
/// IS the enclosing View nominal cannot defer as a leading-dot marker the way
/// `.red` resolves against `Color`: nothing downstream can ever claim it.
/// `ContentUnavailableView.search(text:)` (Harbour's ContainersView.swift:261,
/// Applite, Aidoku, Pulse, pocket-casts) reached a view position as an
/// unresolved `ImplicitMemberCall` and the render threw. Both spellings the
/// SDK declares — the `static var` and the `static func` — must materialize
/// the same pixels the compiler produces.
@Suite(.serialized)
struct GeneratedStaticViewFactoryTests {
    private struct NativeSearchFactoryCallTwin: View {
        let query: String

        var body: some View {
            ContentUnavailableView.search(text: query)
        }
    }

    private struct NativeSearchFactoryPropertyTwin: View {
        var body: some View {
            ContentUnavailableView.search
        }
    }

    @MainActor
    @Test
    func staticViewFactoryCallMatchesNativePixels() throws {
        let source = """
        struct SearchEmptyState: View {
            let query: String
            var body: some View {
                ContentUnavailableView.search(text: query)
            }
        }

        SearchEmptyState(query: "widgets")
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("static view factory call failed: \(rendered)")
            return
        }

        let size = NSSize(width: 320, height: 220)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeSearchFactoryCallTwin(query: "widgets")),
            size: size)
        #expect(Self.pixelAE(actual, expected, size: size) == 0)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    @MainActor
    @Test
    func staticViewFactoryPropertyMatchesNativePixels() throws {
        let source = """
        struct SearchEmptyState: View {
            var body: some View {
                ContentUnavailableView.search
            }
        }

        SearchEmptyState()
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("static view factory property failed: \(rendered)")
            return
        }

        let size = NSSize(width: 320, height: 220)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeSearchFactoryPropertyTwin()), size: size)
        #expect(Self.pixelAE(actual, expected, size: size) == 0)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    /// The two spellings are DIFFERENT views natively (the call form shows the
    /// searched term), so a factory that collapsed both onto one overload
    /// would still pass the two tests above.
    @MainActor
    @Test
    func staticViewFactorySpellingsStayDistinct() throws {
        let size = NSSize(width: 320, height: 220)
        let call = Self.bitmap(
            AnyView(NativeSearchFactoryCallTwin(query: "widgets")),
            size: size)
        let property = Self.bitmap(
            AnyView(NativeSearchFactoryPropertyTwin()), size: size)
        #expect(Self.pixelAE(call, property, size: size) > 0)
    }

    @MainActor
    private static func bitmap(
        _ view: AnyView,
        size: NSSize
    ) -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)!
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private static func pixelAE(
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
}
