import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// The probe walks `NavigationLink` destinations eagerly so a pushed screen's
/// data reaches the tree. A real app's screens link to EACH OTHER, though, so
/// that walk is over a graph with cycles, not a tree: ACHNBrowserUI's
/// ItemDetailView links to ItemsView (ItemDetailView.swift:156) and ItemsView
/// links back to ItemDetailView. Re-entering a screen already being expanded
/// on the current path costs one more full expansion every time, bounded only
/// by the walk's depth guard.
///
/// This is the `achnbrowser-items-ui` live scenario's cost: the other four
/// scenarios on that board finish in under a minute and it runs for ~24, deep
/// in `collect`/`collectRequired` with the depth guard as its only floor.
///
/// The cycle here carries ONE link per screen on purpose. That makes the
/// pre-fix cost linear in the depth guard rather than exponential in the
/// branching factor, so this pins the re-entry property itself and still
/// terminates — a two-link version does not finish at all.
@Suite(.serialized)
struct CyclicDestinationWalkTests {
    private static let mutuallyLinkedScreens = """
    struct ListScreen: View {
        var body: some View {
            VStack {
                Text("list-screen")
                NavigationLink(destination: DetailScreen()) {
                    Text("to-detail")
                }
            }
        }
    }

    struct DetailScreen: View {
        var body: some View {
            VStack {
                Text("detail-screen")
                NavigationLink(destination: ListScreen()) {
                    Text("to-list")
                }
            }
        }
    }

    struct ContentView: View {
        var body: some View {
            NavigationStack {
                ListScreen()
            }
        }
    }
    """

    /// Both screens still get their coverage — the destination walk is what
    /// carries a pushed screen's data into the tree, and that must not regress.
    @Test func aLinkedDestinationIsStillCovered() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.mutuallyLinkedScreens)
        #expect(strings.contains("list-screen"))
        #expect(strings.contains("detail-screen"),
                Comment(rawValue:
                    "a NavigationLink destination must still reach the tree; "
                        + "got \(strings)"))
    }

    /// The property that actually costs the time: a screen already being
    /// expanded on the current path is not expanded again. Covering each
    /// screen once is the whole point of the walk; covering it once per cycle
    /// iteration is what makes a real app's graph unwalkable.
    @Test func aCycleIsNotReExpandedPerIteration() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.mutuallyLinkedScreens)
        let listVisits = strings.filter { $0 == "list-screen" }.count
        let detailVisits = strings.filter { $0 == "detail-screen" }.count
        #expect(listVisits <= 2,
                Comment(rawValue:
                    "the list screen was expanded \(listVisits) times; a cycle "
                        + "must not re-expand a screen already on the walk's "
                        + "own path"))
        #expect(detailVisits <= 2,
                Comment(rawValue:
                    "the detail screen was expanded \(detailVisits) times"))
    }
}
