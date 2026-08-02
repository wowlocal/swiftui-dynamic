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
