import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// MARK: - Native twins

/// The sections a custom view vends, with no modifier on them. Compiled by
/// the real compiler, so what it draws IS the expectation.
private struct NativeBareSections: View {
    var body: some View {
        Section("Alpha") {
            Text("one")
            Text("two")
        }
        Section("Beta") {
            Text("three")
        }
    }
}

/// The same sections carrying the row modifier `InstanceInfoSection` puts on
/// each of its own (`.listRowBackground(theme.primaryBackgroundColor)`).
private struct NativeModifiedSections: View {
    var body: some View {
        Section("Alpha") {
            Text("one")
            Text("two")
        }
        .listRowBackground(Color.yellow)
        Section("Beta") {
            Text("three")
        }
        .listRowBackground(Color.yellow)
    }
}

private struct NativeBareSectionsAcrossBoundary: View {
    var body: some View {
        Form {
            NativeBareSections()
        }
        .formStyle(.grouped)
    }
}

private struct NativeModifiedSectionsInPlace: View {
    var body: some View {
        Form {
            Section("Alpha") {
                Text("one")
                Text("two")
            }
            .listRowBackground(Color.yellow)
            Section("Beta") {
                Text("three")
            }
            .listRowBackground(Color.yellow)
        }
        .formStyle(.grouped)
    }
}

private struct NativeModifiedSectionsAcrossBoundary: View {
    var body: some View {
        Form {
            NativeModifiedSections()
        }
        .formStyle(.grouped)
    }
}

/// Sections produced BY a `ForEach`. This is the route the deleted
/// `ForEachFan.rawValues` carrier existed to serve: the Form used to reach
/// into a fan's uncomposed builder output to find the SectionSpecs inside it.
/// With nothing rebuilding sections, a fan's views are already real Sections
/// by the time the Form sees them — pinned here so the carrier's removal
/// cannot silently regress the shape it was built for.
private struct NativeSectionsFromForEach: View {
    var body: some View {
        Form {
            ForEach(["Alpha", "Beta"], id: \.self) { name in
                Section(name) {
                    Text(name)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Rows with no Section anywhere — the shape the removed implicit wrapper
/// used to own outright.
private struct NativeLooseRows: View {
    var body: some View {
        Form {
            Text("one")
            Text("two")
        }
        .formStyle(.grouped)
    }
}

/// Loose rows ALONGSIDE a section, which is where an implicit wrapper and a
/// real one can disagree about how many boxes there are.
private struct NativeLooseRowsBesideASection: View {
    var body: some View {
        Form {
            Text("loose")
            Section("Alpha") {
                Text("one")
            }
            Text("trailing")
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tests

/// A pixel decomposition of the dominant class in the `instance-info` R2 debt
/// (143,467 AE): grouped `Form` styling loses `Section` structure. The screen
/// that surfaced it is `IceCubesApp/App/Tabs/Settings/InstanceInfoView.swift`,
/// which writes `Form { InstanceInfoSection(instance:) }` while that view's
/// body vends two-to-three `Section`s, each carrying `.listRowBackground`.
///
/// Three ROUTES reach the same defect, and the whole-screen AE cannot tell
/// them apart — so each gets its own observable (`discriminating-repro-refutes`).
///
///   1. THE BOUNDARY. `Form`'s gateway inspects only its own builder output,
///      so sections vended one level down by an interpreted view's body
///      arrive as one opaque value. `bareSectionsAcrossAViewBoundary`.
///   2. THE MODIFIER. Every modifier gateway coerces its receiver through
///      `ViewRegistry.anyView`, so `Section {…}.listRowBackground(…)` reaches
///      the gateway already erased and misses the same inspection.
///      `modifiedSectionsInPlace`.
///   3. Both at once — the real screen's shape, and the one that has to be
///      green for `instance-info` to converge.
///
/// What each route ends in is the SAME emission: the gateway wraps a value it
/// did not recognise as a section in an implicit anonymous `Section`, so the
/// sections inside it nest instead of standing alongside. A native probe
/// measured that wrapper as the entire divergence, and refuted the premise
/// the `SectionSpec` carrier was built on — with `.formStyle(.grouped)` on
/// macOS 26, a `Form` groups an `AnyView`-erased `Section` (AE 0), one vended
/// through a custom view's body (AE 0), one inside an indexed `ForEach`
/// (AE 0) and one carrying a row modifier (AE 0) all identically to a section
/// written directly in its builder. Only wrapping them in another `Section`
/// diverges. `AnyView` erasure does not hide section structure from a `Form`.
///
/// `.formStyle(.grouped)` is explicit because this harness hosts through
/// `NSHostingView` (`microtwin-harness-is-macos-only`) where `Form` defaults
/// to the un-boxed columns style. Grouped is the macOS spelling of the same
/// section semantics the Catalyst R2 board measures: headers OUTSIDE their
/// box, one box per section. Nothing here imports IceCubes.
@Suite(.serialized)
struct FormSectionBoundaryMicroTwinTests {
    private static let size = NSSize(width: 420, height: 320)

    @MainActor
    @Test func bareSectionsAcrossAViewBoundaryStayGrouped() throws {
        let source = """
        struct BareSections: View {
            var body: some View {
                Section(String("Alpha")) {
                    Text(String("one"))
                    Text(String("two"))
                }
                Section(String("Beta")) {
                    Text(String("three"))
                }
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Form {
                        BareSections()
                    }
                    .formStyle(.grouped)
                }
            }
        }
        """
        try Self.expectIdentical(
            source: source,
            native: AnyView(NativeBareSectionsAcrossBoundary()),
            label: "bare-sections-across-boundary")
    }

    @MainActor
    @Test func modifiedSectionsInPlaceStayGrouped() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Form {
                        Section(String("Alpha")) {
                            Text(String("one"))
                            Text(String("two"))
                        }
                        .listRowBackground(Color.yellow)
                        Section(String("Beta")) {
                            Text(String("three"))
                        }
                        .listRowBackground(Color.yellow)
                    }
                    .formStyle(.grouped)
                }
            }
        }
        """
        try Self.expectIdentical(
            source: source,
            native: AnyView(NativeModifiedSectionsInPlace()),
            label: "modified-sections-in-place")
    }

    /// `Form { InstanceInfoSection(instance:) }` distilled: sections vended
    /// across a view boundary AND carrying a row modifier.
    @MainActor
    @Test func modifiedSectionsAcrossAViewBoundaryStayGrouped() throws {
        let source = """
        struct ModifiedSections: View {
            var body: some View {
                Section(String("Alpha")) {
                    Text(String("one"))
                    Text(String("two"))
                }
                .listRowBackground(Color.yellow)
                Section(String("Beta")) {
                    Text(String("three"))
                }
                .listRowBackground(Color.yellow)
            }
        }

        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Form {
                        ModifiedSections()
                    }
                    .formStyle(.grouped)
                }
            }
        }
        """
        try Self.expectIdentical(
            source: source,
            native: AnyView(NativeModifiedSectionsAcrossBoundary()),
            label: "modified-sections-across-boundary")
    }

    /// The route the deleted `rawValues` carrier served. A fan reaching a Form
    /// must still group as one box per section, now that nothing unpacks it.
    @MainActor
    @Test func sectionsVendedByAForEachStayGrouped() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Form {
                        ForEach([String("Alpha"), String("Beta")], id: \\.self) { name in
                            Section(name) {
                                Text(name)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }
        }
        """
        try Self.expectIdentical(
            source: source,
            native: AnyView(NativeSectionsFromForEach()),
            label: "sections-from-foreach")
    }

    /// The counter-direction. Emitting straight through DELETES the implicit
    /// anonymous `Section` the old gateway wrapped every unrecognised value
    /// in, so the routes above could go green by trading one structural
    /// defect for another. Natively a grouped `Form` boxes loose rows itself;
    /// these two pin that it still does when nothing wraps them, both alone
    /// and standing beside a real section — the mixed shape being the one
    /// where an implicit wrapper and a real one disagree about box count.
    @MainActor
    @Test func looseRowsStayGroupedWithNoImplicitSection() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Form {
                        Text(String("one"))
                        Text(String("two"))
                    }
                    .formStyle(.grouped)
                }
            }
        }
        """
        try Self.expectIdentical(
            source: source,
            native: AnyView(NativeLooseRows()),
            label: "loose-rows")
    }

    @MainActor
    @Test func looseRowsBesideASectionKeepBothBoxes() throws {
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Form {
                        Text(String("loose"))
                        Section(String("Alpha")) {
                            Text(String("one"))
                        }
                        Text(String("trailing"))
                    }
                    .formStyle(.grouped)
                }
            }
        }
        """
        try Self.expectIdentical(
            source: source,
            native: AnyView(NativeLooseRowsBesideASection()),
            label: "loose-rows-beside-section")
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
    private static func bitmap(
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
