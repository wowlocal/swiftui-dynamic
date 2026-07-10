import Testing
import SwiftInterpreter
import SwiftUIBridge

/// Property observers run on ASSIGNMENT, not initialization — and a
/// didSet that spawns work (the icecubes fetch-trigger genre:
/// `var timeline { didSet { Task { await fetch() } } }`) executes.
@Suite struct PropertyObserverTests {
    private func run(_ source: String) throws -> RuntimeValue {
        try Interpreter(registry: ViewRegistry()).run(source: source)
    }

    @Test func didSetFiresOnAssignmentNotInit() throws {
        let result = try run("""
        class Model {
            var log: [String] = []
            var value = 0 {
                didSet { self.log.append("didSet \\(oldValue) -> \\(value)") }
            }
        }
        let model = Model()
        model.value = 5
        model.value = 7
        model.log.joined(separator: ", ")
        """)
        #expect(result.stringValue == "didSet 0 -> 5, didSet 5 -> 7")
    }

    @Test func willSetSeesNewValue() throws {
        let result = try run("""
        struct Holder {
            var notes = ""
            var value = 1 {
                willSet { notes += "will \\(newValue);" }
                didSet { notes += "did \\(oldValue);" }
            }
        }
        var holder = Holder()
        holder.value = 9
        holder.notes
        """)
        #expect(result.stringValue == "will 9;did 1;")
    }

    /// winston/VirtualBuddy/SwiftBar (iteration 191): a DECLARED init's
    /// self-stores are DIRECT — observers never fire during initialization.
    /// winston's Nav seeds `@Published var activeTab: Tab { willSet { if
    /// activeTab == newValue … } }` from init; firing the observer there
    /// reads the still-uninitialized property ("cannot compare () and…"),
    /// and observer-writes-property shapes cycle (SwiftBar). Post-init
    /// assignments observe normally.
    @Test func declaredInitStoresBypassObservers() throws {
        let result = try run("""
        enum Tab: String {
            case posts, inbox
        }

        final class Nav: ObservableObject {
            var resets = 0
            var changes = 0
            @Published var activeTab: Tab {
                willSet {
                    if activeTab == newValue { resets += 1 }
                }
                didSet { changes += 1 }
            }

            init(tab: Tab) {
                self.activeTab = tab
            }
        }

        let nav = Nav(tab: .posts)
        let afterInit = (nav.resets, nav.changes)
        nav.activeTab = .posts
        nav.activeTab = .inbox
        (afterInit.0, afterInit.1, nav.resets, nav.changes, nav.activeTab.rawValue)
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 0, "willSet must not fire during init")
        #expect(tuple.values[1].intValue == 0, "didSet must not fire during init")
        #expect(tuple.values[2].intValue == 1, "same-value assignment reads the OLD value in willSet")
        #expect(tuple.values[3].intValue == 2)
        #expect(tuple.values[4].stringValue == "inbox")
    }

    @Test func assignmentInsideDidSetDoesNotRetrigger() throws {
        let result = try run("""
        class Clamp {
            var hits = 0
            var value = 0 {
                didSet {
                    hits += 1
                    if value > 10 { value = 10 }
                }
            }
        }
        let clamp = Clamp()
        clamp.value = 50
        (clamp.value, clamp.hits)
        """)
        #expect(result.stringified == "(10, 1)")
    }

    @Test func customObserverParameterNames() throws {
        let result = try run("""
        class Named {
            var trace = ""
            var value = 0 {
                willSet(incoming) { trace += "in:\\(incoming);" }
                didSet(previous) { trace += "was:\\(previous);" }
            }
        }
        let named = Named()
        named.value = 3
        named.trace
        """)
        #expect(result.stringValue == "in:3;was:0;")
    }
}

/// A bare state write inside a `withAnimation { }` closure (iteration 195,
/// the IceCubes timeline shape): the assignment must land on the instance
/// property even when the mutation runs inside a Task spawned by a didSet.
@Suite struct WithAnimationWriteTests {
    @Test func withAnimationClosureWritesInstanceProperty() throws {
        let source = """
        enum LoadState: Equatable, Sendable {
            enum PagingState: Equatable, Sendable {
                case hasNextPage, none
            }

            case loading
            case display(items: [String], nextPageState: PagingState)
        }

        actor Datasource {
            var stored: [String] = []

            func set(_ items: [String]) {
                stored = items
            }

            func getFilteredItems() -> [String] {
                stored
            }
        }

        @Observable
        @MainActor
        final class VM {
            var state: LoadState = .loading
            @ObservationIgnored
            private let datasource = Datasource()
            private(set) var timelineTask: Task<Void, Never>?
            var timeline: String = "unset" {
                didSet {
                    timelineTask?.cancel()
                    timelineTask = Task {
                        await refresh()
                    }
                }
            }

            func refresh() async {
                await datasource.set(["alpha", "beta"])
                await updateWithAnimation()
            }

            private func updateWithAnimation() async {
                let items = await datasource.getFilteredItems()
                withAnimation {
                    state = .display(items: items, nextPageState: .hasNextPage)
                }
            }
        }

        struct ContentView: View {
            @State private var vm = VM()

            var body: some View {
                content
                    .onAppear {
                        vm.timeline = "trending"
                    }
            }

            @ViewBuilder
            private var content: some View {
                switch vm.state {
                case .loading:
                    Text("still loading")
                case .display(let items, _):
                    ForEach(items, id: \\.self) { item in
                        Text(item)
                    }
                }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("alpha") && strings.contains("beta"),
                "the withAnimation write must land and re-render, got \(strings)")
    }
}

/// SE-0380 if/switch EXPRESSIONS in value position (iteration 195): the
/// IceCubes status filter opens with `let isHidden = if let filterContext
/// { … } else { … }` — dying there silently killed the whole timeline
/// state update (the catch was guarded by a non-empty datasource).
@Suite struct IfSwitchExpressionTests {
    @Test func ifAndSwitchExpressionsInValuePosition() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        func classify(_ n: Int) -> String {
            let sign = if n < 0 { "negative" } else if n == 0 { "zero" } else { "positive" }
            let size = switch abs(n) {
            case 0: "empty"
            case 1..<10: "small"
            default: "large"
            }
            return "\\(sign)-\\(size)"
        }

        let flag: String? = "ctx"
        let isHidden = if let flag { flag == "hide" } else { false }

        protocol AnyItem {
            var filtered: [String]? { get }
        }

        extension AnyItem {
            func isHidden(in context: String) -> Bool {
                filtered?.contains(context) == true
            }

            var isHidden: Bool {
                filtered?.isEmpty == false
            }
        }

        struct Item: AnyItem {
            let filtered: [String]?

            // The type's OWN computed property COLLIDES with the protocol
            // extension's method (the Status.isHidden shape).
            var isHidden: Bool {
                filtered?.isEmpty == false
            }
        }

        actor Source {
            var filterContext: String?

            func setContext(_ context: String?) {
                filterContext = context
            }

            func shouldShow(_ item: Item) -> Bool {
                let hidden = if let filterContext {
                    item.isHidden(in: filterContext)
                } else {
                    item.isHidden
                }
                return !hidden
            }
        }

        let source = Source()
        let visibleWithoutContext = await source.shouldShow(Item(filtered: nil))
        await source.setContext("timeline")
        let visible = await source.shouldShow(Item(filtered: nil))
        _ = visibleWithoutContext
        (classify(-5), classify(0), classify(42), isHidden, visible)
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].stringValue == "negative-small")
        #expect(tuple.values[1].stringValue == "zero-empty")
        #expect(tuple.values[2].stringValue == "positive-large")
        #expect(tuple.values[3].boolValue == false)
        #expect(tuple.values[4].boolValue == true,
                "actor-property if-let shorthand inside an if-expression must bind")
    }
}

/// Layout-protocol conformers, tuple-expression patterns, and the discard
/// sink (iteration 195, the walls after the state write landed).
@Suite struct LayoutAndTuplePatternTests {
    @Test func layoutConformerRendersItsContent() throws {
        let source = """
        struct FitLayout: Layout {
            let originalWidth: CGFloat
            let originalHeight: CGFloat

            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                .zero
            }

            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
        }

        struct ContentView: View {
            var body: some View {
                FitLayout(originalWidth: 640, originalHeight: 360) {
                    Text("media cell")
                }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("media cell"), "the Layout's content must render, got \(strings)")
    }

    @Test func tuplePatternsAndDiscardSink() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        enum Expand: String {
            case hideAll, hideSensitive, show
        }

        func overlay(sensitive: Bool, expand: Expand) -> Bool {
            switch (sensitive, expand) {
            case (_, .hideAll), (true, .hideSensitive):
                true
            default: false
            }
        }

        var log: [String] = []
        _ = log.isEmpty
        _ = overlay(sensitive: false, expand: .show)
        (overlay(sensitive: false, expand: .hideAll),
         overlay(sensitive: true, expand: .hideSensitive),
         overlay(sensitive: false, expand: .hideSensitive),
         overlay(sensitive: false, expand: .show))
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].boolValue == true)
        #expect(tuple.values[1].boolValue == true)
        #expect(tuple.values[2].boolValue == false)
        #expect(tuple.values[3].boolValue == false)
    }
}
