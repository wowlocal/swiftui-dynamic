import Testing

@testable import SwiftUIBridge

/// A view that absorbs unknown members must not LOSE what it renders when a
/// declared modifier is applied to it.
///
/// Surfaced by IceCubes' tab bar (AppView.swift:95), which hangs
/// `.environment(\.symbolVariants, …)` off every tab's label. The absorb
/// fallback minted a fresh empty bag named `Label.environment` in the label's
/// place, so the app's whole tab bar rendered no labels at all and the
/// R3-tab-switch rung had nothing to aim at.
///
/// The class is NOT about tabs, environment, or `Label` — any declared
/// modifier on any closure-less view node erased it, so the cases below pin
/// several unrelated modifiers and a plain `VStack`.
@Suite(.serialized)
struct AbsorbedModifierContentTests {
    private static func source(applying modifier: String) -> String {
        """
        struct ContentView: View {
            var body: some View {
                VStack {
                    Label("label-text", systemImage: "gear")\(modifier)
                }
            }
        }
        """
    }

    /// `Label(_:systemImage:)` takes no closure, so its node absorbs unknown
    /// members — the precondition for the bug. Every one of these is declared
    /// by the generated modifier contract.
    @Test(arguments: [
        ".environment(\\.symbolVariants, .fill)",
        ".foregroundStyle(.red)",
        ".padding()",
        ".opacity(1)",
    ])
    func aDeclaredModifierKeepsTheViewsContent(
        modifier: String
    ) async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.source(applying: modifier))
        #expect(strings.contains("label-text"),
                Comment(rawValue:
                    "\(modifier) erased the view it was applied to: "
                        + "\(strings.filter { !$0.isEmpty })"))
    }

    /// The control: the same view with nothing applied. If this ever fails the
    /// cases above are measuring the wrong thing.
    @Test func theUnmodifiedViewRenders() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.source(applying: ""))
        #expect(strings.contains("label-text"),
                Comment(rawValue: "\(strings.filter { !$0.isEmpty })"))
    }

    /// The absorb bag itself must keep working — this is what the fallback
    /// exists for. `.default` is no view modifier, so a configuration read
    /// still round-trips through the bag even though `Key(…)` renders args.
    @Test func aNonModifierMemberStillAbsorbs() async throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("size-" + String(describing: Key("size").default))
                }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.hasPrefix("size-") },
                Comment(rawValue:
                    "an absorbed configuration read must still answer: "
                        + "\(strings.filter { !$0.isEmpty })"))
    }

    /// The whole tab bar, in the app's own spelling: a value-keyed `TabView`
    /// whose items are nested in a `TabSection`/`ForEach` and whose labels
    /// carry `.environment(\.symbolVariants, …)`. A tab bar shows EVERY tab's
    /// label, so both must render while only the selected tab's content does.
    private static let tabBarSource = """
    enum Screen: Int, Hashable, Identifiable {
        case one, two
        var id: Int { rawValue }
        var title: String { self == .one ? "title-one" : "title-two" }
    }

    struct ContentView: View {
        @State private var screen = Screen.one
        private var screens: [Screen] { [.one, .two] }

        var body: some View {
            TabView(selection: Binding(
                get: { screen },
                set: { screen = $0 })
            ) {
                TabSection("") {
                    ForEach(screens) { entry in
                        Tab(value: entry) {
                            Text("content-\\(entry.title)")
                        } label: {
                            Label(entry.title, systemImage: "gear")
                                .environment(
                                    \\.symbolVariants,
                                    entry == screen ? .fill : .none)
                        }
                    }
                }
            }
        }
    }
    """

    @Test func everyTabLabelSurvivesItsEnvironmentModifier() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.tabBarSource)
        let rendered = strings.filter { !$0.isEmpty }
        #expect(strings.contains("title-one") && strings.contains("title-two"),
                Comment(rawValue:
                    "a tab bar shows every tab's label; got \(rendered)"))
        #expect(strings.contains("content-title-one"),
                Comment(rawValue: "\(rendered)"))
        #expect(!strings.contains("content-title-two"),
                Comment(rawValue:
                    "only the selected tab's content renders; got \(rendered)"))
    }

    /// And the switch itself: aiming at the second tab's label lands its
    /// screen. This is the interaction IceCubesCheck's R3-tab-switch rung
    /// drives against the real app — unreachable while the labels were erased,
    /// because there was nothing on screen to aim at.
    @Test func selectingATabThroughItsModifiedLabelLandsThatScreen()
        async throws
    {
        let after = try await LiveCheckSupport.render(
            source: Self.tabBarSource, afterActions: 1,
            targeting: .renderingText("title-two"))
        #expect(after.strings.contains("content-title-two"),
                Comment(rawValue:
                    "selecting the second tab must land its screen; got "
                        + "\(after.strings.filter { !$0.isEmpty }) among "
                        + "\(after.actionTargets)"))
        #expect(!after.strings.contains("content-title-one"),
                Comment(rawValue:
                    "the tab that was left must no longer be on screen; got "
                        + "\(after.strings.filter { !$0.isEmpty })"))
    }
}
