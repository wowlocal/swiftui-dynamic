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
