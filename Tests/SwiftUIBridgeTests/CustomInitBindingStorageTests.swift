import Testing

@testable import SwiftUIBridge

/// A `@Binding` seeded through a CUSTOM init's backing spelling
/// (`init(group:) { _group = group }`) must accept every spelling of a binding
/// the memberwise boundary accepts — in particular `Binding.constant(v)`.
///
/// IceCubes surfaced this on `TimelineView`
/// (`Packages/Timeline/Sources/Timeline/View/TimelineView.swift:38`), whose
/// public init assigns `_selectedTagGroup = selectedTagGroup`. Driven with the
/// app's own arguments the R2 `trending-timeline` screen passes
/// `selectedTagGroup: .constant(nil)`, and that nil arrived at
/// `TimelineTagGroupheaderView`'s `if let group` as a NON-nil empty stand-in —
/// so the interpreted screen drew a tag-group header (grey
/// `secondaryBackgroundColor` row, "status.action.edit" button, empty tag
/// scroller) that the native twin does not draw at all.
///
/// The sibling header on the same screen, `TimelineTagHeaderView(tag:
/// $viewModel.tag)`, was correct throughout: a PROJECTION was always handled.
/// Only `.constant` was missing, and only at this one boundary — which is why
/// the memberwise cases below stay green in both directions and pin the
/// asymmetry rather than the symptom.
///
/// Expectations are what `swiftc` prints for the same declarations.
@Suite("Custom-init binding storage")
struct CustomInitBindingStorageTests {
    private func strings(_ decl: String, _ body: String) async throws -> [String] {
        try await LiveCheckSupport.renderedStrings(source: """
        final class Group2 {
            var title: String = "DEFAULT"
            init(title: String) { self.title = title }
        }

        \(decl)

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("ROOT")
                    \(body)
                }
            }
        }
        """)
    }

    private static let customInitOuter = """
    struct Outer: View {
        @Binding var group: Group2?
        init(group: Binding<Group2?>) { _group = group }
        var body: some View {
            if let group { Text("SOME-" + group.title) } else { Text("NIL") }
        }
    }
    """

    /// The IceCubes shape: a nil optional through a custom init stays nil, so
    /// `if let` does NOT unwrap. Both spellings of the same call.
    @Test func constantNilThroughACustomInitStaysNil() async throws {
        for call in ["Outer(group: .constant(nil))", "Outer(group: Binding.constant(nil))"] {
            let rendered = try await strings(Self.customInitOuter, call)
            #expect(rendered == ["ROOT", "NIL"], "\(call) rendered \(rendered)")
        }
    }

    /// The class is NOT about optionals: the same boundary dropped the payload
    /// of every constant binding. Without this, `.constant("hello")` read back
    /// as `""` — a silent wrong value rather than a nil-ness bug.
    @Test func constantPayloadSurvivesACustomInit() async throws {
        let decl = """
        struct Titled: View {
            @Binding var title: String
            init(title: Binding<String>) { _title = title }
            var body: some View { Text("VAL-" + title) }
        }
        """
        let call = "Titled(title: .constant(" + "\"hello\"" + "))"
        #expect(try await strings(decl, call) == ["ROOT", "VAL-hello"])
    }

    /// The half that was already right, pinned so the fix cannot trade it away:
    /// a PROJECTION through a custom init still shares the parent's storage, so
    /// a write from the child is visible to the parent. A `.constant` box is
    /// private; a projected box is not, and one rule has to keep both.
    @Test func projectionThroughACustomInitStillSharesStorage() async throws {
        let decl = """
        struct Child: View {
            @Binding var count: Int
            init(count: Binding<Int>) { _count = count }
            var body: some View {
                Button("BUMP") { count += 1 }
            }
        }

        struct Holder: View {
            @State private var count = 0
            var body: some View {
                VStack {
                    Text("COUNT-\\(count)")
                    Child(count: $count)
                }
            }
        }
        """
        let source = """
        \(decl)

        struct ContentView: View {
            var body: some View { Holder() }
        }
        """
        let before = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(before.contains("COUNT-0"))
        let after = try await LiveCheckSupport.renderedStrings(
            source: source, afterActions: 1)
        #expect(after.contains("COUNT-1"), "child write did not reach the parent: \(after)")
    }

    /// The memberwise boundary — which always answered both spellings — is
    /// unchanged. It now shares the rule rather than restating it, so this is
    /// the control that the shared primitive did not narrow anything.
    @Test func memberwiseInitKeepsBothSpellings() async throws {
        let decl = """
        struct Plain: View {
            @Binding var group: Group2?
            var body: some View {
                if let group { Text("SOME-" + group.title) } else { Text("NIL") }
            }
        }

        struct PlainTitled: View {
            @Binding var title: String
            var body: some View { Text("VAL-" + title) }
        }
        """
        #expect(try await strings(decl, "Plain(group: .constant(nil))") == ["ROOT", "NIL"])
        let call = "PlainTitled(title: .constant(" + "\"hello\"" + "))"
        #expect(try await strings(decl, call) == ["ROOT", "VAL-hello"])
    }
}
