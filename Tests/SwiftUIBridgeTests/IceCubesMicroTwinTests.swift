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
    private struct NativeInsetRow: View {
        var body: some View {
            HStack {
                Color.red
                    .frame(width: 16, height: 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .listRowInsets(.init(
                top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }

    private struct NativeInsetListTwin: View {
        var body: some View {
            List {
                NativeInsetRow()
            }
            .listStyle(.plain)
        }
    }

    private struct NativeGeneratedStackSpacingTwin: View {
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Color.red.frame(width: 48, height: 16)
                VStack(spacing: 8) {
                    Color.red.frame(width: 16, height: 16)
                    Color.red.frame(width: 16, height: 16)
                }
            }
        }
    }

    private struct NativeTrailingTagsTwin: View {
        private let tags = ["noticias", "News", "portugal"]

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                        } label: {
                            Text("#\(tag)")
                                .font(.footnote)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private struct NativeInsetRows: View {
        var body: some View {
            ForEach(0..<2) { _ in
                NativeInsetRow()
            }
        }
    }

    private struct NativeComposedInsetListTwin: View {
        var body: some View {
            List {
                NativeInsetRows()
            }
            .listStyle(.plain)
        }
    }

    private struct NativePostModifiedInsetRow: View {
        var body: some View {
            HStack {
                Color.red
                    .frame(width: 16, height: 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .listRowInsets(.init(
                top: 0, leading: 20, bottom: 0, trailing: 20))
            .background {
                Color.clear
            }
        }
    }

    private struct NativePostModifiedInsetListTwin: View {
        var body: some View {
            List {
                NativePostModifiedInsetRow()
            }
            .listStyle(.plain)
        }
    }

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

    @MainActor
    @Test
    func listRowInsetsPropagateFromInterpretedRowBody() throws {
        let source = """
        struct InsetRow: View {
            var body: some View {
                HStack {
                    Color.red
                        .frame(width: 16, height: 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        }

        List {
            InsetRow()
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("row-inset microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 280, height: 120)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeInsetListTwin()), size: size)
        #expect(
            Self.redPixelBounds(actual, size: size)
                == Self.redPixelBounds(expected, size: size))
    }

    @MainActor
    @Test
    func listRowInsetsPropagateThroughCustomCollectionBody() throws {
        let source = """
        struct InsetRow: View {
            var body: some View {
                HStack {
                    Color.red
                        .frame(width: 16, height: 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        }

        struct InsetRows: View {
            var body: some View {
                ForEach(0..<2) { _ in
                    InsetRow()
                }
            }
        }

        List {
            InsetRows()
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("composed row-inset microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 280, height: 160)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeComposedInsetListTwin()), size: size)
        #expect(
            Self.redPixelBounds(actual, size: size)
                == Self.redPixelBounds(expected, size: size))
    }

    @MainActor
    @Test
    func listRowInsetsSurviveFollowingViewModifier() throws {
        let source = """
        struct InsetRow: View {
            var body: some View {
                HStack {
                    Color.red
                        .frame(width: 16, height: 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0, leading: 20, bottom: 0, trailing: 20))
                .background {
                    Color.clear
                }
            }
        }

        List {
            InsetRow()
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("post-modified row-inset microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 280, height: 120)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativePostModifiedInsetListTwin()), size: size)
        #expect(
            Self.redPixelBounds(actual, size: size)
                == Self.redPixelBounds(expected, size: size))
    }

    @MainActor
    @Test
    func listRowInsetsResolveSourceStaticMembersInsideImplicitInitializer()
        throws
    {
        let source = """
        extension CGFloat {
            static var rowInset: CGFloat { 20 }
        }

        struct InsetRow: View {
            var body: some View {
                HStack {
                    Color.red
                        .frame(width: 16, height: 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0,
                    leading: .rowInset,
                    bottom: 0,
                    trailing: .rowInset))
            }
        }

        List {
            InsetRow()
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("contextual row-inset microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 280, height: 120)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeInsetListTwin()), size: size)
        #expect(
            Self.redPixelBounds(actual, size: size)
                == Self.redPixelBounds(expected, size: size))
    }

    /// The compiled Catalyst `ListRowGeometryProbe` measures the red view at
    /// logical x=20 for a 20-point leading row inset. The same source
    /// interpreted through macOS SwiftUI must honor the selected target's
    /// collection baseline instead of composing the macOS host's extra margin.
    @MainActor
    @Test
    func catalystTargetUsesCompiledListRowBaseline() throws {
        let source = """
        struct InsetRow: View {
            var body: some View {
                HStack {
                    Color.red
                        .frame(width: 16, height: 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        }

        List {
            InsetRow()
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("target list-row microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 900, height: 700)
        let bounds = Self.redPixelBounds(
            Self.bitmap(interpreted, size: size), size: size)
        #expect(bounds?.minX == 20)
    }

    /// Interface-derived stack initializers must contextualize shorthand
    /// statics declared by source extensions before scalar coercion. IceCubes
    /// supplies both stack spacings this way; treating the markers as zero
    /// collapses each native eight-point gap.
    @MainActor
    @Test
    func sourceStaticCGFloatControlsGeneratedStackSpacing() throws {
        let source = """
        extension CGFloat {
            static let probeSpacing: CGFloat = 8
        }

        HStack(alignment: .top, spacing: .probeSpacing) {
            Color.red.frame(width: 48, height: 16)
            VStack(spacing: .probeSpacing) {
                Color.red.frame(width: 16, height: 16)
                Color.red.frame(width: 16, height: 16)
            }
        }
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("target nested-layout microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 120, height: 60)
        let actual = Self.redPixelBounds(
            Self.bitmap(interpreted, size: size), size: size)
        let expected = Self.redPixelBounds(
            Self.bitmap(AnyView(NativeGeneratedStackSpacingTwin()), size: size),
            size: size)
        #expect(actual == expected)
    }

    /// A protocol-constrained style value must survive the same
    /// collection/control modifier chain as any other contextual SDK value.
    /// Losing the style turns every bordered control into a plain label and
    /// changes both its pixels and the enclosing row height.
    @MainActor
    @Test
    func borderedSmallButtonsSurviveCustomCollectionComposition() throws {
        let source = """
        let tags = ["noticias", "News", "portugal"]

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \\.self) { tag in
                    Button {
                    } label: {
                        Text("#\\(tag)")
                            .font(.footnote)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .scrollClipDisabled()
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("trailing-tag microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 300, height: 44)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeTrailingTagsTwin()), size: size)
        #expect(Self.pixelAE(actual, expected, size: size) == 0)
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

    private static func redPixelBounds(
        _ bitmap: NSBitmapImageRep,
        size: NSSize
    ) -> CGRect? {
        var minimumX = Int(size.width)
        var minimumY = Int(size.height)
        var maximumX = -1
        var maximumY = -1
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
                where Self.isFooterPixel(bitmap.colorAt(x: x, y: y)) {
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else {
            return nil
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1)
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
