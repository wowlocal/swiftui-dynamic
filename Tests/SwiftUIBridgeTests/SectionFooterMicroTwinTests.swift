import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// MARK: - Native twins
//
// Compiled by the real compiler, so what each draws IS the expectation. The
// class under test: `Section` carries TWO accessory closures in the
// swiftinterface — `header:` and `footer:` — and the gateway read only the
// first, so every section written with a footer lost it and every row below
// moved up by the footer's height. IceCubes writes it at
// `DisplaySettingsView.swift:130`, where the theme section's footer is a
// conditional `Text`. Nothing here imports IceCubes.
//
// `.formStyle(.grouped)` is explicit because this harness hosts through
// `NSHostingView` (`microtwin-harness-is-macos-only`), where `Form` otherwise
// defaults to the un-boxed columns style that has no footer position at all.

private struct NativeHeaderAndFooter: View {
    var body: some View {
        Form {
            Section {
                Text("one")
            } header: {
                Text("Alpha")
            } footer: {
                Text("the footer")
            }
            Section("Beta") {
                Text("two")
            }
        }
        .formStyle(.grouped)
    }
}

/// A footer with NO header. Its own observable because the four accessory
/// combinations are four DIFFERENT `Section` types, not one type with two
/// optional parameters — reading the footer only when a header is also
/// present is a way to be half-right that a header+footer test cannot see.
private struct NativeFooterWithoutHeader: View {
    var body: some View {
        Form {
            Section {
                Text("one")
            } footer: {
                Text("the footer")
            }
            Section("Beta") {
                Text("two")
            }
        }
        .formStyle(.grouped)
    }
}

/// The footer vended one level down, through a custom view's body. The spec
/// defers rendering to the single erasure boundary, so a footer that survives
/// in place can still be dropped on the route a container never sees directly.
private struct FooterSections: View {
    var body: some View {
        Section {
            Text("one")
        } header: {
            Text("Alpha")
        } footer: {
            Text("the footer")
        }
        Section("Beta") {
            Text("two")
        }
    }
}

private struct NativeFooterAcrossBoundary: View {
    var body: some View {
        Form {
            FooterSections()
        }
        .formStyle(.grouped)
    }
}

/// The app's own shape: the footer closure is a bare `if` that is currently
/// FALSE. Natively that is an absent footer, not an empty one — it must
/// reserve no space. This is the counter-direction to the three above: a fix
/// that always passes a footer (an `EmptyView` when there is nothing) would
/// turn all of them green and this one red, because the footer-carrying
/// `Section` overload lays out footer padding whether or not the footer draws.
private struct NativeConditionalFooterAbsent: View {
    private let showsFooter = false
    var body: some View {
        Form {
            Section {
                Text("one")
            } header: {
                Text("Alpha")
            } footer: {
                if showsFooter {
                    Text("the footer")
                }
            }
            Section("Beta") {
                Text("two")
            }
        }
        .formStyle(.grouped)
    }
}

/// The other counter-direction: a header and no footer at all must be
/// untouched by a change that adds a footer position.
private struct NativeHeaderOnly: View {
    var body: some View {
        Form {
            Section {
                Text("one")
            } header: {
                Text("Alpha")
            }
            Section("Beta") {
                Text("two")
            }
        }
        .formStyle(.grouped)
    }
}

@Suite(.serialized)
struct SectionFooterMicroTwinTests {
    private static let size = NSSize(width: 420, height: 320)

    @MainActor
    @Test func headerAndFooterBothRender() throws {
        try Self.expectIdentical(
            source: """
            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        Form {
                            Section {
                                Text(String("one"))
                            } header: {
                                Text(String("Alpha"))
                            } footer: {
                                Text(String("the footer"))
                            }
                            Section(String("Beta")) {
                                Text(String("two"))
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
            }
            """,
            native: AnyView(NativeHeaderAndFooter()),
            label: "header-and-footer")
    }

    @MainActor
    @Test func footerWithoutAHeaderRenders() throws {
        try Self.expectIdentical(
            source: """
            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        Form {
                            Section {
                                Text(String("one"))
                            } footer: {
                                Text(String("the footer"))
                            }
                            Section(String("Beta")) {
                                Text(String("two"))
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
            }
            """,
            native: AnyView(NativeFooterWithoutHeader()),
            label: "footer-without-header")
    }

    @MainActor
    @Test func footerSurvivesAViewBoundary() throws {
        try Self.expectIdentical(
            source: """
            struct FooterSections: View {
                var body: some View {
                    Section {
                        Text(String("one"))
                    } header: {
                        Text(String("Alpha"))
                    } footer: {
                        Text(String("the footer"))
                    }
                    Section(String("Beta")) {
                        Text(String("two"))
                    }
                }
            }

            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        Form {
                            FooterSections()
                        }
                        .formStyle(.grouped)
                    }
                }
            }
            """,
            native: AnyView(NativeFooterAcrossBoundary()),
            label: "footer-across-boundary")
    }

    @MainActor
    @Test func aFalseConditionalFooterReservesNothing() throws {
        try Self.expectIdentical(
            source: """
            struct V: View {
                let showsFooter = false
                var body: some View {
                    Form {
                        Section {
                            Text(String("one"))
                        } header: {
                            Text(String("Alpha"))
                        } footer: {
                            if showsFooter {
                                Text(String("the footer"))
                            }
                        }
                        Section(String("Beta")) {
                            Text(String("two"))
                        }
                    }
                    .formStyle(.grouped)
                }
            }

            @main
            struct P: App {
                var body: some Scene { WindowGroup { V() } }
            }
            """,
            native: AnyView(NativeConditionalFooterAbsent()),
            label: "conditional-footer-absent")
    }

    @MainActor
    @Test func aHeaderWithoutAFooterIsUnchanged() throws {
        try Self.expectIdentical(
            source: """
            @main
            struct P: App {
                var body: some Scene {
                    WindowGroup {
                        Form {
                            Section {
                                Text(String("one"))
                            } header: {
                                Text(String("Alpha"))
                            }
                            Section(String("Beta")) {
                                Text(String("two"))
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
            }
            """,
            native: AnyView(NativeHeaderOnly()),
            label: "header-only")
    }

    /// Native-vs-native controls. Without these, every test above could pass
    /// by drawing NOTHING in the footer position on both sides — the exact
    /// failure they exist to catch. Each asserts that the two native spellings
    /// this suite distinguishes really are visibly different renders.
    @MainActor
    @Test func theNativeFooterIsVisiblyThere() throws {
        let withFooter = Self.bitmap(
            AnyView(NativeHeaderAndFooter()), size: Self.size)
        let withoutFooter = Self.bitmap(
            AnyView(NativeHeaderOnly()), size: Self.size)
        let absentConditional = Self.bitmap(
            AnyView(NativeConditionalFooterAbsent()), size: Self.size)
        #expect(
            Self.pixelAE(withFooter, withoutFooter, size: Self.size) > 0,
            "a drawn footer must differ from no footer at all")
        #expect(
            Self.pixelAE(absentConditional, withoutFooter, size: Self.size) == 0,
            "a footer closure yielding nothing must lay out as no footer")
    }

    // MARK: - Harness

    @MainActor
    private static func expectIdentical(
        source: String,
        native: AnyView,
        label: String
    ) throws {
        RenderDiagnostics.reset()
        let rendered = InterpreterHost().render(
            source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("\(label): interpreted render failed: \(rendered)")
            return
        }
        let interpreted = bitmap(view, size: size)
        let expected = bitmap(native, size: size)
        let ae = pixelAE(interpreted, expected, size: size)
        // The diagnostics ride along because an absorbed modifier reads as a
        // pixel divergence with no other trace of why.
        let diagnostics = RenderDiagnostics.errors
            .prefix(3)
            .map { String($0.error.message.prefix(90)) }
            .joined(separator: " | ")
        #expect(
            ae == 0,
            Comment(rawValue:
                "\(label): interpreted vs natively-compiled AE \(ae)"
                    + " of \(Int(size.width * size.height));"
                    + " diagnostics: \(diagnostics)"))
    }

    @MainActor
    fileprivate static func bitmap(
        _ view: AnyView,
        size: NSSize
    ) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
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

    fileprivate static func pixelAE(
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
