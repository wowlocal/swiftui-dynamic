import AppKit
import SwiftUI
import Testing
import Translation
@testable import SwiftInterpreter
@testable import SwiftUIBridge

extension EnvironmentValues {
    /// Mirrors Env's `@Entry public var isStatusFocused` so the native side of
    /// the focused-status twin selects its font exactly as the app does.
    @Entry var microTwinStatusFocused: Bool = false
}

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

    private struct NativeCompactAccountCountsTwin: View {
        var body: some View {
            HStack(spacing: 12) {
                Text(15_283, format: .number.notation(.compactName))
                Text(1_464, format: .number.notation(.compactName))
                Text(17_989, format: .number.notation(.compactName))
            }
            .font(.footnote)
        }
    }

    /// The whole open media-browser image block (366,896 AE of the R2 board's
    /// 367,681) in one distilled view. `MediaUIView` reaches its image through
    /// `MediaUIZoomableContainer`, whose body is `ZoomableScrollView` — a
    /// representable the APP declares, not one the SDK owns. Nothing in the
    /// bridge builds an interpreted representable conformance, so the whole
    /// subtree is dropped with no diagnostic and no view: the captured
    /// `PlatformGroupContainer` for that screen measures w=0.
    ///
    /// Spelled `NSViewRepresentable` because this suite hosts through
    /// `NSHostingView`; the conformance the interpreter fails to build is the
    /// protocol's, not either platform's, and the Catalyst screen that
    /// surfaced it declares the `UIViewRepresentable` spelling of the same
    /// shape.
    private struct NativeRepresentableBoxTwin: View {
        var body: some View {
            RepresentableBox()
                .frame(width: 120, height: 60)
        }
    }

    private struct RepresentableBox: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.red.cgColor
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// What is LEFT of the media-browser block once the representable itself
    /// executes. `ZoomableScrollView.makeCoordinator` builds
    /// `UIHostingController(rootView: content)` and `makeUIView` adds that
    /// controller's `view` to the scroll view — so the SwiftUI content reaches
    /// the screen only by crossing BACK into UIKit through a hosting
    /// controller. That controller is a GENERIC SDK class
    /// (`UIHostingController<Content> where Content: View`) and the platform
    /// sweep skips every generic initializer ("generic initializer" blocker),
    /// so the construction degrades to an absorbing bag and the board reports
    /// `cannot convert host argument 'p0' of type 'UIKitStub' to expected type
    /// 'UIView'` at the `addSubview`.
    ///
    /// Spelled with AppKit's `NSHostingController` because this suite hosts
    /// through `NSHostingView`; the Catalyst screen that surfaced it declares
    /// the UIKit spelling of the same generic class.
    private struct NativeHostedContent: View {
        var body: some View {
            Color.red
        }
    }

    private struct HostedControllerBox: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let controller = NSHostingController(rootView: NativeHostedContent())
            let hosted = controller.view
            hosted.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
            return hosted
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// The media browser's own shape, one step past the plain hosted
    /// controller above: the hosted content arrives through a `@ViewBuilder`
    /// closure rather than as a type the source constructs at the call, so
    /// what reaches `rootView:` is whatever the builder produced — for
    /// `MediaUIAttachmentImageView` a modifier chain, not a bare struct.
    private struct BuilderHostedBox<Content: View>: NSViewRepresentable {
        private let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        func makeNSView(context: Context) -> NSView {
            let container = NSView()
            let hosted = context.coordinator.hostingController.view
            hosted.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
            container.addSubview(hosted)
            return container
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(hostingController: NSHostingController(rootView: content))
        }

        class Coordinator: NSObject {
            var hostingController: NSHostingController<Content>

            init(hostingController: NSHostingController<Content>) {
                self.hostingController = hostingController
            }
        }
    }

    private struct NativeBuilderHostedTwin: View {
        var body: some View {
            BuilderHostedBox { Color.red }
                .frame(width: 120, height: 60)
        }
    }

    private struct NativeHostedControllerTwin: View {
        var body: some View {
            HostedControllerBox()
                .frame(width: 120, height: 60)
        }
    }

    private struct NativeAvatarShapeTwin: View {
        var body: some View {
            Color.blue
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            Color.primary.opacity(0.25),
                            lineWidth: 1))
        }
    }

    private struct NativeTargetButtonMenuTwin: View {
        var body: some View {
            Menu {
                Button("Action") {}
            } label: {
                Label("", systemImage: "ellipsis")
                    .padding(.vertical, 6)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .tint(.primary)
            .fixedSize()
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

    /// The media preview's own spelling: StatusRowMediaPreviewView.swift:162
    /// hangs `.matchedTransitionSource` off the attachment image. Compiled, the
    /// modifier only registers a transition source — the image keeps every
    /// pixel it had.
    private struct NativeMatchedSourceMedia: View {
        @Namespace private var namespace

        var body: some View {
            Color.blue
                .frame(width: 160, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .matchedTransitionSource(id: "media", in: namespace)
        }
    }

    /// `MediaPreview` frames the attachment, strokes a rounded rect over it,
    /// clips, and rounds the corners — the exact modifier order at
    /// StatusRowMediaPreviewView.swift:141-168.
    private struct NativeStrokedMediaCorner: View {
        var body: some View {
            Color.blue
                .frame(width: 160, height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.gray.opacity(0.35), lineWidth: 1)
                )
                .frame(width: 160, height: 120)
                .clipped()
                .cornerRadius(10)
        }
    }

    /// The same chain with `.matchedTransitionSource` where the app actually
    /// spells it — MID-chain, before the frame/clip/corner that shape the
    /// boundary, not trailing it as `NativeMatchedSourceMedia` does. Absorbing
    /// a trailing modifier is invisible; absorbing one the rest of the chain
    /// wraps changes what those modifiers see.
    private struct NativeMidChainMatchedSourceCorner: View {
        @Namespace private var namespace

        var body: some View {
            Group {
                Color.blue
                    .frame(width: 160, height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.gray.opacity(0.35), lineWidth: 1)
                    )
            }
            .matchedTransitionSource(id: "media", in: namespace)
            .frame(width: 160, height: 120)
            .clipped()
            .cornerRadius(10)
        }
    }

    private struct NativeFocusedStatusText: View {
        @SwiftUI.Environment(\.microTwinStatusFocused) private var isFocused

        var body: some View {
            Text("FUCK FUCK FUCK FUCK NOOOOO")
                .font(isFocused ? .system(size: 21) : .system(size: 19))
        }
    }

    private struct NativeFocusedStatusContent: View {
        var body: some View {
            NativeFocusedStatusText()
        }
    }

    private struct NativeFocusedStatusRow: View {
        var body: some View {
            NativeFocusedStatusContent()
        }
    }

    private struct NativeFocusedStatusTwin: View {
        var body: some View {
            VStack(alignment: .leading) {
                NativeFocusedStatusRow()
                    .environment(\.microTwinStatusFocused, true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
    /// RED at 83d79312: the interpreted representable contributes no view at
    /// all, so this measures the twin's red box against blank — it is the
    /// media-browser image block's whole AE, isolated from the toolbar band
    /// the same screen also carries, exactly as section 1 requires.
    @Test
    func appDeclaredRepresentableDrawsItsNativeView() throws {
        let source = """
        import AppKit

        struct RepresentableBox: NSViewRepresentable {
            func makeNSView(context: Context) -> NSView {
                let view = NSView()
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.red.cgColor
                return view
            }

            func updateNSView(_ nsView: NSView, context: Context) {}
        }

        RepresentableBox()
            .frame(width: 120, height: 60)
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("representable microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 160, height: 100)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeRepresentableBoxTwin()), size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-representable-microtwin ae=\(ae)")
        #expect(ae == 0)
        // The class is SILENT, which is why it survived to be 99.8% of the
        // board's open debt: assert the absence of a diagnostic separately so
        // a future fix cannot pass by merely reporting the failure.
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    /// RED at 3969d9c6: the representable now EXECUTES, but the SwiftUI
    /// content it hosts never becomes a view — `NSHostingController(rootView:)`
    /// is a generic SDK class, the sweep emits no constructor for it, and the
    /// absorbing bag that stands in has no `view` to add.
    @Test
    func hostingControllerDrawsItsInterpretedRootView() throws {
        let source = """
        import AppKit

        struct HostedContent: View {
            var body: some View {
                Color.red
            }
        }

        struct HostedControllerBox: NSViewRepresentable {
            func makeNSView(context: Context) -> NSView {
                let controller = NSHostingController(rootView: HostedContent())
                let hosted = controller.view
                hosted.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
                return hosted
            }

            func updateNSView(_ nsView: NSView, context: Context) {}
        }

        HostedControllerBox()
            .frame(width: 120, height: 60)
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("hosting-controller microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 160, height: 100)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeHostedControllerTwin()), size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-hosting-controller-microtwin ae=\(ae)")
        #expect(ae == 0)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    /// RED at ce5645ff: the media browser's `ZoomableScrollView` reports
    /// `nonthrowing 'func UIView.addSubview(_ p0: UIView) -> Void' threw:
    /// cannot convert '<UIKit.UIView stub>' to generated UIKit type 'UIView'`.
    /// The controller above hosts an interpreted struct and draws; this one
    /// hosts what a `@ViewBuilder` closure produced, which is the app's shape
    /// (`MediaUIZoomableContainer { LazyImage(…)… }`).
    @MainActor
    @Test
    func builderSuppliedRootViewDrawsThroughItsHostingController() throws {
        let source = """
        import AppKit

        struct BuilderHostedBox<Content: View>: NSViewRepresentable {
            private let content: Content

            init(@ViewBuilder content: () -> Content) {
                self.content = content()
            }

            func makeNSView(context: Context) -> NSView {
                let container = NSView()
                let hosted = context.coordinator.hostingController.view
                hosted.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
                container.addSubview(hosted)
                return container
            }

            func updateNSView(_ nsView: NSView, context: Context) {}

            func makeCoordinator() -> Coordinator {
                Coordinator(hostingController: NSHostingController(rootView: content))
            }

            class Coordinator: NSObject {
                var hostingController: NSHostingController<Content>

                init(hostingController: NSHostingController<Content>) {
                    self.hostingController = hostingController
                }
            }
        }

        BuilderHostedBox { Color.red }
            .frame(width: 120, height: 60)
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("builder-hosted microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 160, height: 100)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeBuilderHostedTwin()), size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-builder-hosted-microtwin ae=\(ae)")
        #expect(ae == 0)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

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

    /// The R2 media screen's whole 94,976 AE in one distilled view: a modifier
    /// the bridge does not implement, applied to a view that renders. It was
    /// kept for LAYOUT and hidden — a claim that the RECEIVER draws nothing,
    /// when the only unknown is the modifier's own pixels. Natively the image
    /// is fully drawn, so the interpreted capture must draw it too.
    @MainActor
    @Test
    func matchedTransitionSourceKeepsItsReceiversPixels() throws {
        let source = """
        struct MatchedSourceMedia: View {
            @Namespace private var namespace

            var body: some View {
                Color.blue
                    .frame(width: 160, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .matchedTransitionSource(id: "media", in: namespace)
            }
        }

        MatchedSourceMedia()
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("media microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 220, height: 180)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeMatchedSourceMedia()), size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-media-microtwin ae=\(ae)")
        #expect(ae == 0)
    }

    /// The 3,492 AE left on the R2 media screen, distilled: every delta >= 3
    /// sits in one of the four corner arcs, the straight edges carry a uniform
    /// 1-2, and the interpreted boundary is darker everywhere — it covers more
    /// than the compiled one does.
    @MainActor
    @Test
    func strokedMediaCornerKeepsNativeArcCoverage() throws {
        let source = """
        struct StrokedMediaCorner: View {
            var body: some View {
                Color.blue
                    .frame(width: 160, height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.gray.opacity(0.35), lineWidth: 1)
                    )
                    .frame(width: 160, height: 120)
                    .clipped()
                    .cornerRadius(10)
            }
        }

        StrokedMediaCorner()
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("stroked-corner microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 220, height: 180)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeStrokedMediaCorner()), size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-stroked-corner-microtwin ae=\(ae)")
        #expect(ae == 0)
    }

    /// What the R2 media screen's last open AE was made of. The interpreted arc
    /// ran up to 1.2px OUTSIDE the compiled one at the extreme of each corner
    /// while the straight edges agreed to 0.016px, and the interpreted capture
    /// logged `.matchedTransitionSource` absorbed. Absorbing it mid-chain is
    /// what the following frame/clip/corner then measured against.
    ///
    /// The two neighbours above are the CONTROLS that make this a bisect rather
    /// than an observation: the identical chain without the modifier is AE 0,
    /// and the same modifier TRAILING the chain
    /// (`matchedTransitionSourceKeepsItsReceiversPixels`) is AE 0. So the class
    /// is not the stroke, the clip, or the corner, and not the modifier as
    /// such — it is absorbing a modifier that the rest of the chain wraps.
    ///
    /// It was born a RATCHET at 652 because a measurement-calibrated constant
    /// asserted as equality reds the suite on progress. It is now ZERO, which
    /// is the one bound that cannot be beaten, so the ratchet is spent and the
    /// end state is asserted directly. Reaching it needed
    /// `.matchedTransitionSource(id:in:)` GENERATED rather than absorbed, and
    /// BridgeGen declined it on TWO independent parameters that both had to
    /// fall: `SwiftUICore.Namespace.ID`, which no generated tier carried
    /// because the sweep read only top-level declarations, and the opaque
    /// `some Hashable` id, which had no carrier while its own refinement
    /// `Equatable` did.
    @MainActor
    @Test
    func midChainMatchedSourceKeepsNativeCornerArc() throws {
        let source = """
        struct MidChainMatchedSourceCorner: View {
            @Namespace private var namespace

            var body: some View {
                Group {
                    Color.blue
                        .frame(width: 160, height: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.gray.opacity(0.35), lineWidth: 1)
                        )
                }
                .matchedTransitionSource(id: "media", in: namespace)
                .frame(width: 160, height: 120)
                .clipped()
                .cornerRadius(10)
            }
        }

        MidChainMatchedSourceCorner()
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("mid-chain matched-source microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 220, height: 180)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeMidChainMatchedSourceCorner()), size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-midchain-corner-microtwin ae=\(ae)")
        #expect(ae == 0)
        // Ties the pixels to the MECHANISM. AE 0 alone cannot tell a modifier
        // that dispatched from one that was absorbed and happened not to
        // matter; the absorb path records itself here, so its silence is what
        // says `.matchedTransitionSource` was actually applied.
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

    /// The compiled Catalyst separator oracle resolves the row's semantic
    /// leading guide relative to its 20-point content inset, clamps it at the
    /// visible collection edge, and keeps a platform-owned 20-point trailing
    /// baseline. The macOS host owns separator drawing, so target adaptation
    /// must preserve those properties independently of row content.
    @MainActor
    @Test
    func catalystTargetUsesCompiledListSeparatorSpans() throws {
        let source = """
        struct SeparatorRow: View {
            let guide: CGFloat
            let trailing: CGFloat

            var body: some View {
                HStack {
                    Color.red.frame(width: 16, height: 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(.init(
                    top: 0, leading: 20, bottom: 0, trailing: trailing))
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    guide
                }
            }
        }

        struct SeparatorRows: View {
            var body: some View {
                SeparatorRow(guide: -100, trailing: 0)
                SeparatorRow(guide: 0, trailing: 40)
                SeparatorRow(guide: 20, trailing: 8)
                SeparatorRow(guide: 0, trailing: 20)
            }
        }

        List {
            SeparatorRows()
        }
        .listStyle(.plain)
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("target list-separator microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 900, height: 240)
        let spans = Self.horizontalNeutralSeparatorSpans(
            Self.bitmap(interpreted, size: size), size: size)
        #expect(spans == [0...879, 20...879, 40...879])
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

    /// The compiled Catalyst control-row probe resolves its mixed explicit-
    /// font Button/Menu strip at 32.5 points and each padded repeated row at
    /// 96.5 points. At one-pixel capture scale, the two 40-point red blocks
    /// occupy these exact runs, preserving the half-point row cadence.
    @MainActor
    @Test
    func catalystTargetPreservesMixedControlRowExtent() throws {
        let source = """
        struct GeometryOnlyButtonStyle: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
            }
        }

        struct TargetActionButton: View {
            var body: some View {
                Button {} label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 19))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GeometryOnlyButtonStyle())
            }
        }

        struct TargetActionMenu: View {
            var body: some View {
                Menu {
                    Button("Action") {}
                } label: {
                    Label("", systemImage: "ellipsis")
                        .font(.system(size: 19))
                        .padding(.vertical, 6)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .tint(.primary)
                .contentShape(Rectangle())
            }
        }

        struct TargetControlRows: View {
            var body: some View {
                ForEach(0..<2) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        Color.red.frame(width: 40, height: 40)
                        HStack {
                            TargetActionButton()
                            TargetActionButton()
                            Spacer()
                            TargetActionMenu()
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.init(
                        top: 12, leading: 0, bottom: 6, trailing: 0))
                    .listRowInsets(.init(
                        top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
        }

        List {
            TargetControlRows()
        }
        .listStyle(.plain)
        .environment(\\.colorScheme, .light)
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("target control-row microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 900, height: 220)
        let bitmap = Self.bitmap(interpreted, size: size)
        #expect(Self.redPixelYRuns(bitmap, size: size) == [
            12..<52,
            109..<148,
        ])
    }

    /// The compiled Catalyst trailing-control oracle resolves semantic
    /// footnote labels at 16 points, small bordered controls and their
    /// horizontal ScrollView at 26 points, and each padded repeated row at 98
    /// points. The two fixed green blocks therefore start exactly 98 points
    /// apart without accumulating host scroll-container height.
    @MainActor
    @Test
    func catalystTargetPreservesTrailingControlRowExtent() throws {
        let source = """
        struct TargetTrailingControl: View {
            let index: Int

            var body: some View {
                Button {} label: {
                    Text("#control-\\(index)")
                        .font(.footnote)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        struct TargetTrailingControlStrip: View {
            var body: some View {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            TargetTrailingControl(index: index)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }

        struct TargetTrailingControlRows: View {
            var body: some View {
                ForEach(0..<2) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        Color.green.frame(width: 40, height: 40)
                        TargetTrailingControlStrip()
                            .padding(.top, 8)
                    }
                    .padding(.init(
                        top: 12, leading: 0, bottom: 6, trailing: 0))
                    .listRowInsets(.init(
                        top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
        }

        List {
            TargetTrailingControlRows()
        }
        .listStyle(.plain)
        .environment(\\.colorScheme, .light)
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record(
                "target trailing-control row microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 900, height: 220)
        let bitmap = Self.bitmap(interpreted, size: size)
        #expect(Self.greenPixelYRuns(bitmap, size: size) == [
            12..<52,
            110..<150,
        ])
    }

    /// The compiled Catalyst typography oracle records the semantic footnote
    /// label at 48×16 independently of button chrome. A macOS host otherwise
    /// selects its own smaller 36×12 footnote metrics.
    @MainActor
    @Test
    func catalystTargetPreservesSemanticFootnoteExtent() throws {
        let source = """
        Text("Control")
            .font(.footnote)
            .fontWeight(.medium)
            .lineLimit(1)
            .background(Color.red)
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("target footnote microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 200, height: 100)
        let bitmap = Self.bitmap(interpreted, size: size)
        guard let bounds = Self.redPixelBounds(
            bitmap, size: size)
        else {
            Issue.record("target footnote microtwin rendered no red extent")
            return
        }
        #expect(bounds.size == CGSize(width: 48, height: 16))
    }

    /// Once target typography supplies the native 48×16 label, the compiled
    /// target's closed ControlSize table contributes 10×5 for mini/small,
    /// 12×7 for regular, and 20×15 for large/extra-large chrome.
    @MainActor
    @Test
    func catalystTargetPreservesBorderedControlExtents() throws {
        let size = NSSize(width: 200, height: 100)
        let expectations: [(String, CGSize)] = [
            ("mini", CGSize(width: 68, height: 26)),
            ("small", CGSize(width: 68, height: 26)),
            ("regular", CGSize(width: 72, height: 30)),
            ("large", CGSize(width: 88, height: 46)),
            ("extraLarge", CGSize(width: 88, height: 46)),
        ]
        for (controlSize, expected) in expectations {
            let source = """
            Button {} label: {
                Text("Control")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.\(controlSize))
            .background(Color.red)
            """

            let rendered = InterpreterHost().render(
                source: source,
                buildConfiguration: .init(
                    platformName: "iOS", targetEnvironment: "macCatalyst"),
                lazyTopLevelGlobals: true)
            guard case .success(let interpreted) = rendered,
                  let bounds = Self.redPixelBounds(
                    Self.bitmap(interpreted, size: size), size: size)
            else {
                Issue.record(
                    "target \(controlSize) control microtwin failed: \(rendered)")
                continue
            }
            #expect(bounds.size == expected)
        }
    }

    /// The compiled Catalyst oracle resolves an untinted bordered control to
    /// a neutral surface while preserving the ambient accent for its label.
    /// Supplying `.tint(.red)` changes the surface to the target's tinted
    /// fill. A custom host style must preserve that explicitness
    /// property instead of treating the default accent as an explicit tint.
    @MainActor
    @Test
    func catalystTargetPreservesBorderedControlFillSemantics() throws {
        let size = NSSize(width: 200, height: 100)
        let variants: [(suffix: String, expectedRGB: [Int])] = [
            ("", [233, 233, 235]),
            (".tint(.red)", [255, 219, 220]),
        ]
        for variant in variants {
            let source = """
            Button {} label: {
                Text("Control")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            \(variant.suffix)
            """

            let rendered = InterpreterHost().render(
                source: source,
                buildConfiguration: .init(
                    platformName: "iOS", targetEnvironment: "macCatalyst"),
                lazyTopLevelGlobals: true)
            guard case .success(let interpreted) = rendered else {
                Issue.record(
                    "target bordered-fill microtwin failed: \(rendered)")
                continue
            }
            let bitmap = Self.bitmap(interpreted, size: size)
            #expect(
                Self.dominantNonWhiteRGB(bitmap, size: size)
                    == variant.expectedRGB)
        }
    }

    /// A generated protocol value may cross an environment boundary before a
    /// target adapter consumes it. Reopening that existential at the native
    /// generic call must render exactly like passing the concrete style
    /// directly; early `AnyShapeStyle` erasure changes edge rasterization.
    @MainActor
    @Test
    func generatedShapeStyleCarrierMatchesConcreteNativeFill() throws {
        let size = NSSize(width: 80, height: 80)
        let shape = RoundedRectangle(
            cornerRadius: 17, style: .continuous)
        let carrier = try #require(GeneratedShapeStyleCarrier(Color.red))
        let actual = Self.bitmap(
            carrier.fill(shape, opacity: 0.5), size: size)
        let expected = Self.bitmap(
            AnyView(shape.fill(Color.red.opacity(0.5))), size: size)

        #expect(Self.pixelAE(actual, expected, size: size) == 0)
    }

    /// Compiled Catalyst's button-style menu presents only its supplied label;
    /// the macOS host adds a disclosure indicator that widens the control and
    /// alters its intrinsic geometry. The target default is interface-
    /// inexpressible, so the selected target style must supply it without
    /// requiring source code to spell `.menuIndicator(.hidden)`.
    @MainActor
    @Test
    func catalystTargetButtonMenuUsesLabelOnlyChrome() throws {
        let source = """
        Menu {
            Button("Action") {}
        } label: {
            Label("", systemImage: "ellipsis")
                .padding(.vertical, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .tint(.primary)
        .fixedSize()
        """

        let rendered = InterpreterHost().render(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("target button-menu microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 160, height: 80)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeTargetButtonMenuTwin()), size: size)
        #expect(Self.pixelAE(actual, expected, size: size) == 0)
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

    /// AccountStatsView passes integer counts through the associated
    /// `FormatStyle` initializer and then refines its contextual factory with
    /// `.notation(.compactName)`. Both links come from SDK interface metadata;
    /// falling back to verbatim integers widens every account-stat label.
    @MainActor
    @Test
    func compactAccountCountsUseGeneratedAssociatedFormatStyle() throws {
        let rendered = InterpreterHost().render(
            source: """
            HStack(spacing: 12) {
                Text(15_283, format: .number.notation(.compactName))
                Text(1_464, format: .number.notation(.compactName))
                Text(17_989, format: .number.notation(.compactName))
            }
            .font(.footnote)
            """,
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("compact-count microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 240, height: 60)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeCompactAccountCountsTwin()), size: size)
        #expect(Self.pixelAE(actual, expected, size: size) == 0)
    }

    /// IceCubes' AvatarImage applies an interface-generated RoundedRectangle
    /// at both a generic clipShape boundary and a generic stroke boundary.
    /// The generated constructor must keep the interface's `.continuous`
    /// default and generic operations must reopen the concrete Shape.
    @MainActor
    @Test
    func concreteRoundedShapeOperationsMatchAvatarChain() throws {
        let shapeValue = try Interpreter(registry: ViewRegistry()).run(
            source: "RoundedRectangle(cornerRadius: 24)")
        let generatedShape = try #require(
            shapeValue.hostPayload as? RoundedRectangle)
        #expect(generatedShape.style == .continuous)

        let rendered = InterpreterHost().render(
            source: """
            Color.blue
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            Color.primary.opacity(0.25),
                            lineWidth: 1))
            """,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("avatar-shape microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 80, height: 80)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeAvatarShapeTwin()), size: size)
        #expect(Self.pixelAE(actual, expected, size: size) == 0)
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
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("trailing-tag microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 300, height: 120)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeTrailingTagsListTwin()), size: size)
        // This composition test deliberately uses host typography and list
        // geometry; target-specific metrics have independent compiled oracles.
        // Align collection origins, then require every control pixel to remain
        // native-identical.
        #expect(Self.alignedContentPixelAE(
            actual, expected, size: size) == 0)
    }

    /// IceCubes' focused status is the only row on the detail screen rendered at
    /// `Font.scaledBodyFocused` — `body + 2`, two points larger than every other
    /// row (DesignSystem/Font.swift:61). `StatusRowTextView` selects it from
    /// `\.isStatusFocused` (StatusRowTextView.swift:29), an `@Entry` value
    /// declared in the Env package (Env/CustomEnvValues.swift:13) and applied by
    /// `StatusDetailView` two composition levels above the leaf that reads it
    /// (StatusDetailView.swift:132). Losing the value across that module and
    /// composition boundary renders the focused status one font step small and
    /// shifts every later row up — the whole-screen `status-detail` R2 debt.
    @MainActor
    @Test
    func focusedStatusEntryValueReachesNestedRowText() throws {
        let environment = ProjectMaterial.mergedSource(source: """
        import SwiftUI

        extension EnvironmentValues {
            @Entry public var isStatusFocused: Bool = false
        }
        """, moduleName: "Env")
        let statusKit = ProjectMaterial.mergedSource(source: """
        import Env
        import SwiftUI

        struct StatusRowTextView: View {
            @Environment(\\.isStatusFocused) private var isFocused

            var body: some View {
                Text("FUCK FUCK FUCK FUCK NOOOOO")
                    .font(isFocused
                        ? .system(size: 21)
                        : .system(size: 19))
            }
        }

        struct StatusRowContentView: View {
            var body: some View {
                StatusRowTextView()
            }
        }

        struct StatusRowView: View {
            var body: some View {
                StatusRowContentView()
            }
        }

        VStack(alignment: .leading) {
            StatusRowView()
                .environment(\\.isStatusFocused, true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        """, moduleName: "StatusKit")

        let rendered = InterpreterHost().render(
            source: environment + statusKit,
            lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("focused-status microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 400, height: 60)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeFocusedStatusTwin()), size: size)
        print("@@icecubes-focused-status-microtwin ae="
            + "\(Self.pixelAE(actual, expected, size: size))")
        #expect(Self.pixelAE(actual, expected, size: size) == 0)
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

    /// IceCubes' `Models/Alias/ServerDate.swift:18`, distilled to the one
    /// expression that draws: a relative timestamp is
    /// `Duration.seconds(-date.timeIntervalSinceNow).formatted(.units(width:
    /// .narrow, maximumUnitCount: 1))`, and `ServerDate.init()` pins
    /// `asDate = Date() - 100`, so every example post on the display-settings
    /// screen is exactly `Duration.seconds(100)` under this style.
    ///
    /// RED before the nominal same-type static sweep: `Duration.seconds(100)`
    /// had no way to be BUILT — the interface sweep read static storage but not
    /// static FUNCS — so the receiver stayed an unresolved leading-dot marker,
    /// `.formatted(…)` absorbed into a chain, and the label drew EMPTY against
    /// a native "2m".
    ///
    /// This measures the timestamp BY ITSELF rather than through the
    /// display-settings whole-screen AE, so a row-render win cannot be masked
    /// by anything else on that screen.
    private struct NativeRelativeTimestampTwin: View {
        var body: some View {
            Text(Duration.seconds(100).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @Test
    func namedDurationTimestampDrawsItsFormattedText() throws {
        let source = """
        Text(Duration.seconds(100).formatted(
            .units(width: .narrow, maximumUnitCount: 1)))
            .font(.footnote)
            .foregroundStyle(.secondary)
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let interpreted) = rendered else {
            Issue.record("relative-timestamp microtwin failed: \(rendered)")
            return
        }

        let size = NSSize(width: 120, height: 40)
        let actual = Self.bitmap(interpreted, size: size)
        let expected = Self.bitmap(
            AnyView(NativeRelativeTimestampTwin()), size: size)
        let ae = Self.pixelAE(actual, expected, size: size)
        print("@@icecubes-relative-timestamp-microtwin ae=\(ae)")
        #expect(ae == 0)
        // The class draws NOTHING rather than something wrong, so an empty
        // capture on BOTH sides would read as agreement. Require the native
        // side to have actually drawn the glyphs this is measuring.
        #expect(Self.pixelAE(
            expected,
            Self.bitmap(AnyView(Color.clear), size: size),
            size: size) > 0)
        #expect(RenderDiagnostics.errors.isEmpty)
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

    private static func greenPixelYRuns(
        _ bitmap: NSBitmapImageRep,
        size: NSSize
    ) -> [Range<Int>] {
        let populatedRows = (0..<Int(size.height)).filter { y in
            (0..<Int(size.width)).contains { x in
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB)
                else {
                    return false
                }
                return color.greenComponent > 0.70
                    && color.greenComponent
                        > color.redComponent + 0.20
                    && color.greenComponent
                        > color.blueComponent + 0.20
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

    private static func horizontalNeutralSeparatorSpans(
        _ bitmap: NSBitmapImageRep,
        size: NSSize
    ) -> [ClosedRange<Int>] {
        var spans: [ClosedRange<Int>] = []
        for y in 0..<Int(size.height) {
            let neutral = (0..<Int(size.width)).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB)
                else {
                    return false
                }
                return color.redComponent > 0.80
                    && color.redComponent < 0.98
                    && abs(color.redComponent - color.greenComponent) < 0.01
                    && abs(color.redComponent - color.blueComponent) < 0.01
            }
            guard neutral.count > 700,
                  let first = neutral.first,
                  let last = neutral.last,
                  last - first + 1 == neutral.count
            else {
                continue
            }
            let span = first...last
            if spans.last != span {
                spans.append(span)
            }
        }
        return spans
    }

    private static func dominantNonWhiteRGB(
        _ bitmap: NSBitmapImageRep,
        size: NSSize
    ) -> [Int] {
        var counts: [UInt32: Int] = [:]
        for x in 0..<Int(size.width) {
            for y in 0..<Int(size.height) {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB)
                else {
                    continue
                }
                let red = Int((color.redComponent * 255).rounded())
                let green = Int((color.greenComponent * 255).rounded())
                let blue = Int((color.blueComponent * 255).rounded())
                guard red < 250 || green < 250 || blue < 250 else {
                    continue
                }
                let key = UInt32(red << 16 | green << 8 | blue)
                counts[key, default: 0] += 1
            }
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else {
            return []
        }
        return [
            Int((key >> 16) & 0xff),
            Int((key >> 8) & 0xff),
            Int(key & 0xff),
        ]
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
