import AppKit
import SwiftUI
import Testing
import Translation
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// Pixel metrics distilled from IceCubes' StatusesListView. Keep the row and
/// trailing pagination geometry independent so either failure can move without
/// the other hiding it in the full-screen AE total.
@Suite(.serialized)
struct IceCubesMicroTwinTests {
    private struct NativeTranslatedRow: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 72)
                .translationPresentation(
                    isPresented: .constant(false),
                    text: title)
        }
    }

    private struct NativePaginationTwin: View {
        var body: some View {
            List {
                NativeTranslatedRow(title: "ROW A")
                NativeTranslatedRow(title: "ROW B")
                Text("NEXT PAGE")
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .listStyle(.plain)
        }
    }

    /// `StatusesListView.makeNextPageRow` follows every translated status row.
    /// Compare only the red footer mask: row rendering is a separate metric,
    /// while every footer pixel must occupy the native position exactly.
    @MainActor
    @Test
    func paginationFooterPositionIsIndependentOfTranslatedRowPixels() throws {
        let source = """
        import Translation

        struct TranslatedRow: View {
            let title: String
            var body: some View {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .translationPresentation(
                        isPresented: .constant(false),
                        text: title)
            }
        }

        List {
            TranslatedRow(title: "ROW A")
            TranslatedRow(title: "ROW B")
            Text("NEXT PAGE")
                .font(.footnote)
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("footer microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 280, height: 240)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativePaginationTwin()), size: size)
        let expectedFooterPixels = Self.footerPixelCount(
            expected, size: size)
        #expect(expectedFooterPixels > 20)
        #expect(
            Self.footerPixelCount(actual, size: size)
                == expectedFooterPixels)
        #expect(Self.footerMaskAE(actual, expected, size: size) == 0)
    }

    private static func isFooterPixel(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return color.redComponent > 0.65
            && color.greenComponent < 0.45
            && color.blueComponent < 0.45
    }

    private static func footerPixelCount(
        _ bitmap: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        var count = 0
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
                where Self.isFooterPixel(bitmap.colorAt(x: x, y: y)) {
                count += 1
            }
        }
        return count
    }

    private static func footerMaskAE(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        var mismatched = 0
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
                where Self.isFooterPixel(lhs.colorAt(x: x, y: y))
                    != Self.isFooterPixel(rhs.colorAt(x: x, y: y)) {
                mismatched += 1
            }
        }
        return mismatched
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
}
