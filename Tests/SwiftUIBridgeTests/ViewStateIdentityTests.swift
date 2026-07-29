import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Compiled SwiftUI keeps per-identity @State alive across re-renders —
/// the probe's multi-pass render must see pass-N writes in pass N+1
/// (the icecubes genre: .onAppear assigns the view model's client, the
/// NEXT pass fetches with it).
@Suite struct ViewStateIdentityTests {
    private static let lazyListPaginationSource = """
    final class Model {
        var visibleRows = 0
        var pageLoads = 0
    }
    let model = Model()

    struct NextPageRow: View {
        let model: Model
        var body: some View {
            Text("next page")
                .task { model.pageLoads += 1 }
        }
    }

    @main struct DemoApp: App {
        var body: some Scene {
            WindowGroup {
                VStack {
                    List {
                        ForEach(0..<24, id: \\.self) { value in
                            Text("row \\(value)")
                                .onAppear { model.visibleRows += 1 }
                        }
                        NextPageRow(model: model)
                    }
                    Text("lifecycle \\(model.visibleRows)|\\(model.pageLoads)")
                }
            }
        }
    }
    """

    @Test func onAppearWriteSurvivesRerender() async throws {
        let source = """
        class FeedModel {
            var status = "empty"
        }
        struct FeedView: View {
            @State var model = FeedModel()
            var body: some View {
                Text(model.status)
                    .onAppear { model.status = "loaded" }
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { FeedView() }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.contains("loaded") },
                "re-render lost the onAppear write: \(strings)")
    }

    @Test func stateBoxReusedAcrossInstantiations() async throws {
        let source = """
        class Counter {
            var value = 0
        }
        struct CounterView: View {
            @State var counter = Counter()
            var body: some View {
                Text("count \\(counter.value)")
                    .onAppear { counter.value += 1 }
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { CounterView() }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        // Passes fire onAppear once per NEW closure only; the count must
        // exceed zero in the final tree (identity held), never reset.
        #expect(strings.contains { $0.contains("count") && !$0.contains("count 0") },
                "state reset across renders: \(strings)")
    }

    @Test func insertedLifecycleViewDoesNotShiftExistingIdentity() async throws {
        let source = """
        final class Model {
            var revealsNewView = false
            var newAppearances = 0
            var stableAppearances = 0
        }
        struct ContentView: View {
            @State private var model = Model()

            var body: some View {
                VStack {
                    if model.revealsNewView {
                        Text("new")
                            .onAppear { model.newAppearances += 1 }
                    }
                    Text("stable")
                        .onAppear {
                            model.stableAppearances += 1
                            model.revealsNewView = true
                        }
                    Text("\\(model.newAppearances)|\\(model.stableAppearances)")
                }
            }
        }
        """

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("1|1"),
                "lifecycle identity followed array position: \(strings)")
    }

    @Test func lifecycleIdentityDistinguishesForEachRows() async throws {
        let source = """
        final class Model {
            var appearanceTotal = 0
        }
        struct ContentView: View {
            @State private var model = Model()

            var body: some View {
                VStack {
                    ForEach([1, 2], id: \\.self) { value in
                        Text("row \\(value)")
                            .onAppear { model.appearanceTotal += value }
                    }
                    Text("total \\(model.appearanceTotal)")
                }
            }
        }
        """

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("total 3"),
                "sibling rows shared one lifecycle identity: \(strings)")
    }

    /// Distilled from IceCubes' reusable Nuke `LazyImage`: every instance's
    /// lifecycle modifier originates at the same source site inside `body`,
    /// but SwiftUI gives sibling component instances distinct structural
    /// identities inherited from their parent construction sites.
    @Test func lifecycleIdentityDistinguishesReusableViewInstances() async throws {
        let source = """
        final class Model {
            var appearanceTotal = 0
        }
        struct ReusableRow: View {
            let value: Int
            let model: Model

            var body: some View {
                Text("row \\(value)")
                    .onAppear { model.appearanceTotal += value }
            }
        }
        struct ContentView: View {
            @State private var model = Model()

            var body: some View {
                VStack {
                    ReusableRow(value: 1, model: model)
                    ReusableRow(value: 2, model: model)
                    Text("total \\(model.appearanceTotal)")
                }
            }
        }
        """

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("total 3"),
                "reusable instances shared one lifecycle identity: \(strings)")
    }

    /// Distilled from IceCubes' StatusesListView + NextPageView. A native
    /// List materializes only its initial viewport, so the trailing paging
    /// task is still off-screen at launch even though visible row callbacks
    /// have begun. The trace walk may cover every row's strings, but it must
    /// not turn deep coverage into lifecycle visibility.
    @Test func lazyListDoesNotFireOffscreenPaginationTaskAtLaunch() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.lazyListPaginationSource,
            initialViewportRowCapacity: 19)
        let summary = try #require(strings.first { $0.hasPrefix("lifecycle ") })
        #expect(summary.hasSuffix("|0"),
                "off-screen paging task fired at launch: \(strings)")
        #expect(summary != "lifecycle 0|0",
                "initially visible rows never appeared: \(strings)")
    }

    /// Integration counterpart to the launch pin above: after the initial
    /// viewport is quiescent, traversing through the end materializes the
    /// remaining native-lazy rows and the trailing pagination task exactly
    /// once. This is a container-property rule, not a NextPageView hook.
    @Test func scrollingLazyListMaterializesPaginationTask() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.lazyListPaginationSource,
            viewportTraversal: .throughEnd,
            initialViewportRowCapacity: 19)
        let summary = try #require(strings.first { $0.hasPrefix("lifecycle ") })
        #expect(summary == "lifecycle 24|1",
                "scroll traversal did not materialize each row once: \(strings)")
    }

    /// IceCubes' paging footer reaches its fetcher through a generic protocol
    /// witness captured by an async-throwing closure, then invoked from the
    /// footer's private async helper. The concrete reference must survive
    /// every one of those type-erased source boundaries.
    @Test func scrollingLazyListRunsCapturedAsyncProtocolWitness() async throws {
        let source = """
        @MainActor protocol PageFetching: Sendable {
            var items: [Int] { get }
            var pageLoads: Int { get }
            func fetchNextPage() async throws
        }

        @MainActor final class FeedModel: PageFetching {
            var items = Array(0..<20)
            var pageLoads = 0

            func fetchNextPage() async throws {
                items.append(20)
                pageLoads += 1
            }
        }

        @MainActor struct PagingFooter: View {
            @State private var isLoading = false
            let loadNextPage: () async throws -> Void

            var body: some View {
                Text("next page")
                    .task { await executeTask() }
            }

            private func executeTask() async {
                guard !isLoading else { return }
                isLoading = true
                defer { isLoading = false }
                try? await loadNextPage()
            }
        }

        @MainActor struct Feed<Fetcher: PageFetching>: View {
            @State private var fetcher: Fetcher

            init(fetcher: Fetcher) {
                _fetcher = .init(initialValue: fetcher)
            }

            var body: some View {
                List {
                    ForEach(fetcher.items, id: \\.self) { item in
                        Text("row \\(item)")
                    }
                    PagingFooter {
                        try await fetcher.fetchNextPage()
                    }
                }
                Text("summary \\(fetcher.items.count)|\\(fetcher.pageLoads)")
            }
        }

        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { Feed(fetcher: FeedModel()) }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(
            source: source, viewportTraversal: .throughEnd,
            initialViewportRowCapacity: 19)
        #expect(strings.contains("summary 21|1"),
                "async protocol witness mutation was lost: \(strings)")
    }

    /// Once a lifecycle mutation has produced a larger tree, a render with no
    /// new lifecycle and no outstanding runtime work is already the
    /// quiescent presentation. Re-rendering only to confirm the string count
    /// wastes a complete deep traversal of large applications.
    @Test func quiescentStringGrowthDoesNotRequireConfirmationRender()
        async throws
    {
        let source = """
        final class Model {
            var rows = [0]
            var renders = 0
        }
        let model = Model()

        struct ContentView: View {
            var body: some View {
                let _ = model.renders += 1
                VStack {
                    ForEach(model.rows, id: \\.self) { row in
                        Text("row \\(row)")
                    }
                    Text("renders \\(model.renders)")
                }
                .onAppear {
                    model.rows.append(1)
                }
            }
        }

        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { ContentView() }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(
            source: source)
        #expect(strings.contains("row 1"))
        #expect(strings.contains("renders 2"),
                "quiescent growth caused a redundant render: \(strings)")
    }

    /// A lazy scroll reuses launch-visible rows. The post-scroll coverage pass
    /// should therefore evaluate only the previously off-screen tail, while
    /// ordinary siblings outside the lazy container still observe the final
    /// state.
    @Test func scrollingLazyListReusesInitiallyVisibleRowBodies() async throws {
        let source = """
        final class Model {
            var rowBodies = 0
            var pageLoads = 0
        }
        let model = Model()

        struct CountedRow: View {
            let value: Int

            var body: some View {
                let _ = model.rowBodies += 1
                Text("row \\(value)")
            }
        }

        struct BodyCountProbe: View {
            var body: some View {
                Text("bodies \\(model.rowBodies)")
                Text("loads \\(model.pageLoads)")
            }
        }

        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup {
                    VStack {
                        List {
                            ForEach(0..<20, id: \\.self) { value in
                                CountedRow(value: value)
                            }
                            Text("next")
                                .task { model.pageLoads += 1 }
                        }
                        BodyCountProbe()
                    }
                }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(
            source: source, viewportTraversal: .throughEnd,
            initialViewportRowCapacity: 19)
        #expect(strings.contains("bodies 20"),
                "launch-visible row bodies were rebuilt on scroll: \(strings)")
        #expect(strings.contains("loads 1"))
    }

    @Test func taskIdentityRestartsWhenItsIDChanges() async throws {
        let source = """
        final class Model {
            var taskID = 0
            var runs = 0
        }
        struct ContentView: View {
            @State private var model = Model()

            var body: some View {
                Text("runs \\(model.runs)")
                    .task(id: model.taskID) {
                        model.runs += 1
                        if model.taskID == 0 {
                            model.taskID = 1
                        }
                    }
            }
        }
        """

        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("runs 2"),
                "task(id:) did not restart exactly once: \(strings)")
    }
}
