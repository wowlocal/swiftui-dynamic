import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// IceCubes `TagRowView` class (DesignSystem/Views/TagRowView.swift:19):
/// `Text("design.tag.n-posts-from-n-participants \(tag.totalUses) \(tag.totalAccounts)")`
/// is a LocalizedStringKey literal, and SwiftUI formats an interpolated number
/// in a localization key under the CURRENT LOCALE — the twin draws `4,097`
/// where the interpreter drew `4097`. That one missing grouping separator was
/// 630 of the 634 AE left on the `tags-list` R2 screen after the chart axes
/// were fixed.
///
/// Each expectation is native-verified in the strongest available way: the
/// EXPECTED side is the same literal compiled by real swiftc in this file, and
/// the two are compared pixel-exactly. Nothing here hard-codes `4,097` as a
/// string, so if SwiftUI's own formatting changes, both sides move together
/// and the test keeps measuring the interpreter rather than a frozen guess.
@Suite struct LocalizedInterpolationTests {
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

    /// Differing-pixel count between two same-sized captures.
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
    private static func interpreted(_ body: String) throws -> AnyView {
        try interpreted(declarations: "", body: body)
    }

    @MainActor
    private static func interpreted(
        declarations: String, body: String
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

    private static let size = NSSize(width: 300, height: 60)

    /// The failing class itself. RED before the fix at 630 AE — the grouped
    /// and ungrouped strings are different glyph runs of different widths.
    @MainActor
    @Test func localizedKeyInterpolationGroupsIntegerLikeTheCompiler() throws {
        let interpreted = try Self.interpreted("""
                    Text("posts \\(4097) \\(176)")
        """)
        let native = Text("posts \(4097) \(176)")
        let error = Self.absoluteError(
            Self.rasterize(interpreted, size: Self.size),
            Self.rasterize(native, size: Self.size))
        #expect(error == 0, "interpreted localized key differs by \(error) px")
    }

    /// The control that makes the test above non-degenerate: if the
    /// interpreter simply never drew anything, both halves would be blank and
    /// AE would be 0. This measures the grouped-vs-ungrouped drift the fix
    /// removes, against a natively-compiled VERBATIM rendering of the same
    /// numbers, and requires it to be non-zero.
    @MainActor
    @Test func groupedAndUngroupedRenderingsActuallyDiffer() throws {
        let grouped = Text("posts \(4097) \(176)")
        let ungrouped = Text(verbatim: "posts 4097 176")
        let error = Self.absoluteError(
            Self.rasterize(grouped, size: Self.size),
            Self.rasterize(ungrouped, size: Self.size))
        #expect(error > 100, "control drift only \(error) px; the two readings must differ")
    }

    /// Over-application guard, and the reason this lives on the call argument
    /// rather than on the value: SwiftUI picks `Text(_: LocalizedStringKey)`
    /// over `Text(_: some StringProtocol)` by the argument being a LITERAL.
    /// The same interpolation bound to a `String` first is verbatim — `4097`,
    /// NOT `4,097` — on both sides.
    @MainActor
    @Test func stringTypedArgumentStaysVerbatim() throws {
        let interpreted = try Self.interpreted(
            declarations: """
                let label: String = "posts \\(4097) \\(176)"
            """,
            body: """
                        Text(label)
            """)
        let native = Text("posts \(4097) \(176)" as String)
        let error = Self.absoluteError(
            Self.rasterize(interpreted, size: Self.size),
            Self.rasterize(native, size: Self.size))
        #expect(error == 0, "String-typed argument differs by \(error) px")
    }

    /// A bare `%` in the literal is NOT a format directive: native
    /// `String(localized: "50% off \(4097)")` is `50% off 4,097`. The fix
    /// formats each interpolation independently and leaves text verbatim, so
    /// there is no format string for a stray `%` to corrupt.
    @MainActor
    @Test func literalPercentSurvivesBesideAFormattedNumber() throws {
        let interpreted = try Self.interpreted("""
                    Text("50% off \\(4097)")
        """)
        let native = Text("50% off \(4097)")
        let error = Self.absoluteError(
            Self.rasterize(interpreted, size: Self.size),
            Self.rasterize(native, size: Self.size))
        #expect(error == 0, "percent-bearing key differs by \(error) px")
    }

    /// Adjacent interpolations are formatted SEPARATELY, not as one number:
    /// native `String(localized: "\(1234)\(5678)")` is `1,2345,678`. A format
    /// string built by concatenating specifiers would produce the same thing
    /// here, but a single grouped `12,345,678` would not — this pins which.
    @MainActor
    @Test func adjacentInterpolationsGroupIndependently() throws {
        let interpreted = try Self.interpreted("""
                    Text("\\(1234)\\(5678)")
        """)
        let native = Text("\(1234)\(5678)")
        let error = Self.absoluteError(
            Self.rasterize(interpreted, size: Self.size),
            Self.rasterize(native, size: Self.size))
        #expect(error == 0, "adjacent interpolations differ by \(error) px")
    }

    /// The rule is the value's numeric identity, not a spelled type name:
    /// `Double` carries `%lf`, so native renders six decimal places AND the
    /// grouping separator (`4,097.500000`) — visibly unlike `4097.5`.
    @MainActor
    @Test func doubleInterpolationUsesItsOwnSpecifier() throws {
        let interpreted = try Self.interpreted("""
                    Text("\\(4097.5)")
        """)
        let native = Text("\(4097.5)")
        let error = Self.absoluteError(
            Self.rasterize(interpreted, size: Self.size),
            Self.rasterize(native, size: Self.size))
        #expect(error == 0, "Double interpolation differs by \(error) px")
    }

    /// A non-specifiable type keeps interpolating verbatim. `String` has no
    /// format specifier, so a key containing only string interpolations must
    /// be byte-identical to what it always was.
    @MainActor
    @Test func stringInterpolationIsUnaffected() throws {
        let interpreted = try Self.interpreted("""
                    Text("hello \\(String("4097"))")
        """)
        let native = Text("hello \(String("4097"))")
        let error = Self.absoluteError(
            Self.rasterize(interpreted, size: Self.size),
            Self.rasterize(native, size: Self.size))
        #expect(error == 0, "String interpolation differs by \(error) px")
    }
}
