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

    @MainActor
    @Observable
    final class NativeRouteStore {
        enum Destination {
            case hashTag(tag: String, account: String?)
        }

        func navigate(to destination: Destination) {}
    }

    private struct NativeTrailingTagsTwin: View {
        @SwiftUI.Environment(NativeRouteStore.self)
        private var router: NativeRouteStore

        private let tags = ["noticias", "News", "portugal"]

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            router.navigate(to: .hashTag(
                                tag: tag, account: nil))
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

    private struct NativeTrailingTagsContentTwin: View {
        var body: some View {
            VStack(alignment: .leading) {
                if true {
                    NativeTrailingTagsTwin()
                        .padding(.top, 8)
                }
            }
        }
    }

    private struct NativeTrailingTagsListTwin: View {
        var body: some View {
            List {
                NativeTrailingTagsContentTwin()
                    .environment(NativeRouteStore())
            }
            .listStyle(.plain)
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

    private struct NativeRepeatedPaddedRows: View {
        var body: some View {
            ForEach(0..<2) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Color.red.frame(width: 16, height: 16)
                    Color.red.frame(width: 16, height: 16)
                }
                .padding(.init(
                    top: 12, leading: 0, bottom: 6, trailing: 0))
                .listRowInsets(.init(
                    top: 0, leading: 20, bottom: 0, trailing: 20))
            }
        }
    }

    private struct NativeRepeatedPaddedList: View {
        var body: some View {
            List {
                NativeRepeatedPaddedRows()
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

    /// IceCubes' status rows terminate at the Translation/SwiftUI cross-import
    /// modifier on the interpreted iOS path. The inactive presentation must
    /// preserve every native receiver pixel, independently of the footer.
    @MainActor
    @Test
    func translatedRowPreservesNativePixels() throws {
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

        TranslatedRow(title: "VISIBLE STATUS ROW")
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("row microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 280, height: 100)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeTranslatedRow(title: "VISIBLE STATUS ROW")),
            size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-row-microtwin ae=\(ae)")
        #expect(ae == 0)
        #expect(RenderDiagnostics.errors.isEmpty)
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

    /// The compiled Catalyst repeated-row probe records four 16-point red
    /// bands whose leading edges are separated by 24, 34, and 24 points.
    /// That pins the complete 58-point child extent through a custom
    /// collection body: 12 top + 16 content + 8 spacing + 16 content + 6
    /// bottom.
    @MainActor
    @Test
    func catalystTargetPreservesPaddingAcrossRepeatedRows() throws {
        let source = """
        struct RepeatedRows: View {
            var body: some View {
                ForEach(0..<2) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Color.red.frame(width: 16, height: 16)
                        Color.red.frame(width: 16, height: 16)
                    }
                    .padding(.init(
                        top: 12, leading: 0, bottom: 6, trailing: 0))
                    .listRowInsets(.init(
                        top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
        }

        List {
            RepeatedRows()
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("target repeated-row microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 900, height: 160)
        let runs = Self.redPixelYRuns(
            Self.bitmap(interpreted, size: size), size: size)
        let hostRuns = Self.redPixelYRuns(
            Self.bitmap(
                AnyView(NativeRepeatedPaddedList()), size: size),
            size: size)
        #expect(runs == hostRuns)
        #expect(runs.map(\.count) == [16, 16, 16, 16])
        #expect(zip(runs, runs.dropFirst()).map {
            $1.lowerBound - $0.lowerBound
        } == [24, 34, 24])
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
        let models = ProjectMaterial.mergedSource(source: """
        public struct Tag: Identifiable {
            public let name: String

            public var id: String {
                name
            }

            public init(name: String) {
                self.name = name
            }
        }
        """, moduleName: "Models")
        let environment = ProjectMaterial.mergedSource(source: """
        public enum Destination {
            case hashTag(tag: String, account: String?)
        }

        @MainActor
        @Observable
        public final class RouteStore {
            public init() {
            }

            public func navigate(to destination: Destination) {
            }
        }
        """, moduleName: "Env")
        let row = ProjectMaterial.mergedSource(source: """
        import Env
        import Models
        import SwiftUI

        struct AlternateButtonStyle: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
            }
        }

        extension ButtonStyle where Self == AlternateButtonStyle {
            static func alternate(
                isOn: Bool = false,
                tintColor: Color? = nil
            ) -> Self {
                AlternateButtonStyle()
            }
        }

        struct TrailingTags: View {
            @Environment(RouteStore.self) private var router

            let tags: [Tag]

            var body: some View {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags) { tag in
                            Button {
                                router.navigate(to: .hashTag(
                                    tag: tag.name, account: nil))
                            } label: {
                                Text("#\\(tag.name)")
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

        struct RowContent: View {
            let tags: [Tag]

            var body: some View {
                VStack(alignment: .leading) {
                    if !tags.isEmpty {
                        TrailingTags(tags: tags)
                            .padding(.top, 8)
                    }
                }
            }
        }

        List {
            RowContent(tags: [
                Tag(name: "noticias"),
                Tag(name: "News"),
                Tag(name: "portugal"),
            ])
            .environment(RouteStore())
        }
        .listStyle(.plain)
        """, moduleName: "StatusKit")
        let source = models + environment + row

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("trailing-tag microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 300, height: 120)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeTrailingTagsListTwin()), size: size)
        // The selected Catalyst target deliberately removes the macOS
        // List's outer leading margin (covered by the list-baseline twin).
        // Normalize that one collection translation, then require every
        // control/content pixel to remain native-identical.
        #expect(Self.alignedContentPixelAE(
            actual, expected, size: size) == 0)
    }

    private static func isContentPixel(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return color.redComponent < 0.99
            || color.greenComponent < 0.99
            || color.blueComponent < 0.99
    }

    private static func contentPixelBounds(
        _ bitmap: NSBitmapImageRep,
        size: NSSize
    ) -> CGRect? {
        var minimumX = Int(size.width)
        var minimumY = Int(size.height)
        var maximumX = -1
        var maximumY = -1
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
                where Self.isContentPixel(bitmap.colorAt(x: x, y: y)) {
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

    private static func alignedContentPixelAE(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        guard let lhsBounds = Self.contentPixelBounds(lhs, size: size),
              let rhsBounds = Self.contentPixelBounds(rhs, size: size),
              lhsBounds.size == rhsBounds.size
        else {
            return Int.max
        }
        var mismatched = 0
        for x in 0..<Int(lhsBounds.width) {
            for y in 0..<Int(lhsBounds.height)
                where lhs.colorAt(
                    x: Int(lhsBounds.minX) + x,
                    y: Int(lhsBounds.minY) + y)
                    != rhs.colorAt(
                        x: Int(rhsBounds.minX) + x,
                        y: Int(rhsBounds.minY) + y) {
                mismatched += 1
            }
        }
        return mismatched
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

    private static func pixelAE(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        size: NSSize
    ) -> Int {
        var mismatched = 0
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height)
                where lhs.colorAt(x: x, y: y)
                    != rhs.colorAt(x: x, y: y) {
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

    private static func redPixelYRuns(
        _ bitmap: NSBitmapImageRep,
        size: NSSize
    ) -> [Range<Int>] {
        let populatedRows = (0..<Int(size.height)).filter { y in
            (0..<Int(size.width)).contains { x in
                Self.isFooterPixel(bitmap.colorAt(x: x, y: y))
            }
        }
        guard let first = populatedRows.first else { return [] }
        var runs: [Range<Int>] = []
        var lowerBound = first
        var previous = first
        for row in populatedRows.dropFirst() {
            if row != previous + 1 {
                runs.append(lowerBound..<(previous + 1))
                lowerBound = row
            }
            previous = row
        }
        runs.append(lowerBound..<(previous + 1))
        return runs
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
