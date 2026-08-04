import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// `Text` is not the only API that takes a `LocalizedStringKey`. The SDK
/// interfaces declare that parameter on 155 generated sites — `Button`,
/// `Label`, `Toggle`, `TextField`, `.navigationTitle`, `Section` — and each one
/// formats its interpolations under the current locale exactly as `Text` does.
/// Reading the verbatim `String` at those parameters loses the same grouping
/// separator the `tags-list` screen surfaced on `Text`, so this measures the
/// rule where the interface declares it rather than where it was first found.
///
/// Every expectation is native-verified the same way `LocalizedInterpolationTests`
/// does it: the EXPECTED side is the same literal compiled by real swiftc in
/// this file, compared pixel-exactly. Nothing hard-codes `4,097`.
@Suite struct LocalizedKeyParameterTests {
    @MainActor
    private static func rasterize(
        _ view: some View, size: NSSize
    ) -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: AnyView(
                view.frame(width: size.width, height: size.height)
                    .background(Color.white)))
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

    @MainActor
    private static func absoluteError(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep
    ) -> Int {
        guard let a = lhs.bitmapData, let b = rhs.bitmapData,
              lhs.bytesPerRow == rhs.bytesPerRow,
              lhs.pixelsHigh == rhs.pixelsHigh else { return .max }
        var differing = 0
        for row in 0..<lhs.pixelsHigh {
            for column in 0..<lhs.pixelsWide {
                let offset = row * lhs.bytesPerRow + column * 4
                if a[offset] != b[offset] || a[offset + 1] != b[offset + 1]
                    || a[offset + 2] != b[offset + 2] {
                    differing += 1
                }
            }
        }
        return differing
    }

    @MainActor
    private static func interpreted(
        declarations: String = "", body: String
    ) throws -> AnyView {
        let source = """
        struct P2: View {
        \(declarations)
            var body: some View {
        \(body)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    P2()
                }
            }
        }
        """
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            throw RenderFailure()
        }
        return view
    }

    private struct RenderFailure: Error {}

    private static let size = NSSize(width: 320, height: 80)

    @MainActor
    private static func expectMatches(
        _ interpretedSource: String,
        declarations: String = "",
        _ native: some View,
        _ what: String
    ) throws {
        let interpreted = try Self.interpreted(
            declarations: declarations, body: interpretedSource)
        let error = Self.absoluteError(
            Self.rasterize(interpreted, size: Self.size),
            Self.rasterize(native, size: Self.size))
        #expect(error == 0, "\(what) differs by \(error) px")
    }

    /// A constructor label parameter. `Button.init(_ titleKey:action:)` is a
    /// localization key, so `4097` renders `4,097` on the native side.
    @MainActor
    @Test func buttonTitleReadsItsKeyLocalized() throws {
        try Self.expectMatches(
            """
                        Button("posts \\(4097)") { }
            """,
            Button("posts \(4097)") { },
            "Button title")
    }

    /// The same parameter one layer up: `Label.init(_ titleKey:systemImage:)`.
    @MainActor
    @Test func labelTitleReadsItsKeyLocalized() throws {
        try Self.expectMatches(
            """
                        Label("posts \\(4097)", systemImage: "star")
            """,
            Label("posts \(4097)", systemImage: "star"),
            "Label title")
    }

    /// A control whose key sits beside a binding, proving the substitution is
    /// per-parameter rather than per-call.
    @MainActor
    @Test func toggleTitleReadsItsKeyLocalized() throws {
        try Self.expectMatches(
            """
                        Toggle("posts \\(4097)", isOn: .constant(true))
            """,
            Toggle("posts \(4097)", isOn: .constant(true)),
            "Toggle title")
    }

    /// A MODIFIER parameter, not a constructor one — the same interface type
    /// reached through the other generated table. `.badge` is chosen because
    /// it draws its key inline, so the comparison against native is direct.
    @MainActor
    @Test func badgeReadsItsKeyLocalized() throws {
        try Self.expectMatches(
            """
                        List { Text("row").badge("posts \\(4097)") }
            """,
            List { Text("row").badge("posts \(4097)") },
            "badge")
    }

    /// Non-degeneracy for the modifier path, measured the same way as for the
    /// constructor path: the two readings must actually differ natively.
    @MainActor
    @Test func groupedAndUngroupedBadgesDiffer() throws {
        let grouped = List { Text("row").badge("posts \(4097)") }
        let verbatim = List { Text("row").badge("posts 4097" as String) }
        let error = Self.absoluteError(
            Self.rasterize(grouped, size: Self.size),
            Self.rasterize(verbatim, size: Self.size))
        #expect(error > 50, "control drift only \(error) px; readings must differ")
    }

    /// The HANDWRITTEN modifier tier. `.navigationTitle`, `.alert` and
    /// `.confirmationDialog` are the three key-taking modifiers that still have
    /// handwritten gateways, and they inherit the reading from the same shared
    /// function rather than each learning the rule.
    ///
    /// Native SwiftUI puts a macOS navigation title in the window's toolbar,
    /// not in the captured content view, so an interpreted-vs-native capture
    /// cannot see it — measured, not assumed: two natively-compiled stacks
    /// whose titles differ compare at AE 0. The interpreter draws its own
    /// chrome into the content, so the chrome is held constant on both sides
    /// and only the READING varies: the literal must render exactly as the
    /// natively-computed `String(localized:)` of the same literal, and that
    /// must differ from the verbatim string.
    @MainActor
    @Test func handwrittenNavigationTitleReadsItsKeyLocalized() throws {
        let nativeKeyReading = String(localized: "posts \(4097)")
        let nativeVerbatimReading = "posts \(4097)" as String

        func titled(_ title: String) throws -> AnyView {
            try Self.interpreted(
                declarations: "    let t: String = \"\(title)\"",
                body: """
                            NavigationStack {
                                Color.white.navigationTitle(t)
                            }
                """)
        }
        let literal = try Self.interpreted(body: """
                        NavigationStack {
                            Color.white.navigationTitle("posts \\(4097)")
                        }
            """)

        let drift = Self.absoluteError(
            Self.rasterize(try titled(nativeKeyReading), size: Self.size),
            Self.rasterize(try titled(nativeVerbatimReading), size: Self.size))
        #expect(drift > 50, "control drift only \(drift) px; readings must differ")

        let error = Self.absoluteError(
            Self.rasterize(literal, size: Self.size),
            Self.rasterize(try titled(nativeKeyReading), size: Self.size))
        #expect(error == 0, "handwritten navigationTitle differs by \(error) px")
    }

    /// The over-application guard, and the reason the reading lives beside the
    /// argument: a `String`-typed expression selects the verbatim overload at
    /// every one of these parameters too, so it must still render `4097`.
    @MainActor
    @Test func stringTypedButtonTitleStaysVerbatim() throws {
        try Self.expectMatches(
            """
                        Button(label) { }
            """,
            declarations: """
                let label: String = "posts \\(4097)"
            """,
            Button("posts \(4097)" as String) { },
            "String-typed Button title")
    }

    /// Non-degeneracy: if the interpreter drew nothing, every AE above would be
    /// 0 for the wrong reason. This requires the two readings to actually
    /// differ natively at one of these parameters.
    @MainActor
    @Test func groupedAndUngroupedButtonTitlesDiffer() throws {
        let grouped = Button("posts \(4097)") { }
        let verbatim = Button("posts 4097" as String) { }
        let error = Self.absoluteError(
            Self.rasterize(grouped, size: Self.size),
            Self.rasterize(verbatim, size: Self.size))
        #expect(error > 50, "control drift only \(error) px; readings must differ")
    }
}
