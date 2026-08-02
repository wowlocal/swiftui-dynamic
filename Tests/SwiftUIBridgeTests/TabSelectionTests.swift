import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// Value-based tab selection — the third screen transition an app can make and
/// the one IceCubes' whole shell is built from. `AppView.tabBarView`
/// (AppView.swift:77) is a single `TabView(selection:)` whose content is
/// `Tab(value:) { … } label: { … }` items inside `TabSection`s, so until a tab
/// can be selected the app has exactly one reachable screen.
///
/// `Tab` conforms to `TabContent`, not `View`, which is why it is generated
/// from the interface rather than hand-written here.
@Suite(.serialized)
struct TabSelectionTests {
    private enum Screen: Hashable { case one, two }

    /// The compiled expectation: with the selection bound to the second tab,
    /// the second tab's content is painted and the first tab's is not.
    private struct NativeSelected: View {
        let first: String
        let selection: Screen
        var body: some View {
            TabView(selection: .constant(selection)) {
                Tab("one-label", systemImage: "1.circle", value: Screen.one) {
                    Text(first)
                }
                Tab("two-label", systemImage: "2.circle", value: Screen.two) {
                    Text("screen-two")
                }
            }
        }
    }

    /// Pinned against the real compiler rather than assumed, in two halves: the
    /// selection decides what is painted, and the UNSELECTED tab's content is
    /// not painted at all. The second half is measured by changing only the
    /// first tab's content — if that text were on screen, the pixels would
    /// move. Tab LABELS stay identical in both, so the tab bar is not what is
    /// being compared.
    @Test @MainActor func compiledTabViewPaintsOnlyTheSelectedTabsContent() throws {
        let size = NSSize(width: 380, height: 220)
        let selectedTwo = ObservableBindingProbe.bitmap(
            AnyView(NativeSelected(first: "screen-one", selection: .two)),
            size: size)
        let selectedTwoOtherContent = ObservableBindingProbe.bitmap(
            AnyView(NativeSelected(first: "XXXXXXXXXXXX", selection: .two)),
            size: size)
        let selectedOne = ObservableBindingProbe.bitmap(
            AnyView(NativeSelected(first: "screen-one", selection: .one)),
            size: size)

        func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            var count = 0
            for x in 0..<Int(size.width) {
                for y in 0..<Int(size.height)
                where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) {
                    count += 1
                }
            }
            return count
        }
        #expect(differing(selectedTwo, selectedTwoOtherContent) == 0,
                "the unselected tab's content must not be painted")
        #expect(differing(selectedTwo, selectedOne) > 0,
                "the selection must decide which tab's content is painted")
    }

    private static let selectedSource = """
    enum Screen: Hashable { case one, two }

    struct ContentView: View {
        @State private var screen: Screen = .two

        var body: some View {
            TabView(selection: $screen) {
                Tab("one-label", systemImage: "1.circle", value: Screen.one) {
                    Text("screen-one")
                }
                Tab("two-label", systemImage: "2.circle", value: Screen.two) {
                    Text("screen-two")
                }
            }
        }
    }
    """

    @Test func theSelectedTabRendersItsOwnContent() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.selectedSource)
        #expect(strings.contains("screen-two"),
                Comment(rawValue:
                    "a TabView bound to the second tab's value must render "
                        + "that tab's content; got \(strings)"))
        #expect(!strings.contains("screen-one"),
                Comment(rawValue:
                    "the unselected tab's content must not be on screen, as "
                        + "the compiled TabView paints it; got \(strings)"))
    }

    /// A tab item is a control whose action is to select itself: firing it
    /// writes its own value into the TabView's selection. This is how any tab
    /// switch in a real app happens, and what the R3 rung drives.
    private static let switchSource = """
    enum Screen: Hashable { case one, two }

    struct ContentView: View {
        @State private var screen: Screen = .one

        var body: some View {
            TabView(selection: $screen) {
                Tab("one-label", systemImage: "1.circle", value: Screen.one) {
                    Text("screen-one")
                }
                Tab("two-label", systemImage: "2.circle", value: Screen.two) {
                    Text("screen-two")
                }
            }
        }
    }
    """

    @Test func firingATabItemSelectsIt() async throws {
        let before = try await LiveCheckSupport.renderedStrings(
            source: Self.switchSource)
        #expect(before.contains("screen-one"))
        #expect(!before.contains("screen-two"))

        let after = try await LiveCheckSupport.render(
            source: Self.switchSource, afterActions: 1,
            targeting: .renderingText("two-label"))
        #expect(after.strings.contains("screen-two"),
                Comment(rawValue:
                    "selecting the second tab must land on its screen; got "
                        + "\(after.strings) among \(after.actionTargets)"))
        #expect(!after.strings.contains("screen-one"),
                Comment(rawValue:
                    "the tab that was left must no longer be on screen; got "
                        + "\(after.strings)"))
    }

    /// IceCubes' shell spells all three of these at once (AppView.swift:77):
    /// the selection is a COMPUTED binding routing writes through the app's
    /// own `updateTab(with:)`, the items are nested inside a `TabSection`
    /// inside a `ForEach`, and each carries a separate `label:` builder
    /// instead of a title argument. Distilled here so the shape is pinned by
    /// seconds of unit test rather than only by the whole app.
    ///
    /// Spelled `Binding(...)` here on purpose: the app's own `.init(get:set:)`
    /// spelling is a separate class — whether a contextual initializer in an
    /// argument becomes a binding at all — and is measured by
    /// `ContextualBindingArgumentTests`. Keeping both spellings pinned in
    /// their own suites means a regression in either one names itself.
    private static let appShellSource = """
    struct Screen: Hashable, Identifiable {
        let id: Int
        let name: String
    }

    struct ContentView: View {
        @State private var screen = 1
        @State private var writes = 0

        private var screens: [Screen] {
            [Screen(id: 1, name: "one"), Screen(id: 2, name: "two")]
        }

        var body: some View {
            TabView(selection: Binding(
                get: { screen },
                set: { newScreen in
                    writes += 1
                    screen = newScreen
                })
            ) {
                TabSection("section-title") {
                    ForEach(screens) { entry in
                        Tab(value: entry.id) {
                            Text("content-\\(entry.name)")
                        } label: {
                            Text("label-\\(entry.name)")
                        }
                    }
                }
            }
            Text("writes-\\(writes)")
        }
    }
    """

    @Test func theAppShellSpellingSelectsThroughItsComputedBinding()
        async throws
    {
        let before = try await LiveCheckSupport.renderedStrings(
            source: Self.appShellSource)
        #expect(before.contains("content-one"),
                Comment(rawValue: "got \(before)"))
        #expect(!before.contains("content-two"),
                Comment(rawValue:
                    "only the selected tab's content renders when the items "
                        + "are nested in a TabSection/ForEach; got \(before)"))
        // Both labels are on screen either way: a tab bar shows every tab.
        #expect(before.contains("label-one") && before.contains("label-two"),
                Comment(rawValue: "got \(before)"))

        let after = try await LiveCheckSupport.render(
            source: Self.appShellSource, afterActions: 1,
            targeting: .renderingText("label-two"))
        #expect(after.strings.contains("content-two"),
                Comment(rawValue:
                    "selecting through a computed binding must land on the "
                        + "second tab; got \(after.strings) among "
                        + "\(after.actionTargets)"))
        #expect(!after.strings.contains("content-one"),
                Comment(rawValue: "got \(after.strings)"))
        // The app's own setter ran — IceCubes routes the write through
        // `updateTab(with:)`, so a selection that bypassed it would skip
        // everything the app does on a tab change.
        #expect(after.strings.contains("writes-1"),
                Comment(rawValue:
                    "the computed binding's set() must run exactly once; got "
                        + "\(after.strings)"))
    }

    /// A `TabView` with no selection keeps its existing behavior exactly — the
    /// change is additive for every app that never binds one.
    private static let unselectedSource = """
    struct ContentView: View {
        var body: some View {
            TabView {
                Text("plain-one").tabItem { Text("one-label") }
                Text("plain-two").tabItem { Text("two-label") }
            }
        }
    }
    """

    @Test func aTabViewWithoutSelectionIsUnchanged() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.unselectedSource)
        #expect(strings.contains("plain-one"),
                Comment(rawValue: "got \(strings)"))
    }
}
