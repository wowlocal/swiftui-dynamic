import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A `Binding` built inline as an argument, written the way the SDK's own
/// declaration lets you write it: `.init(get:set:)`, with the value type
/// supplied by the parameter rather than by the call. IceCubes' whole shell
/// hangs off one (`AppView.swift:78` —
/// `TabView(selection: .init(get: { selectedTab }, set: { updateTab(with: $0) }))`),
/// and until this resolves, the argument is filed as configuration and the
/// container never sees a binding at all.
///
/// The explicit `Binding(get:set:)` spelling already worked; this is the same
/// value written the other way, so both spellings must reach the one
/// closure-backed Binding primitive.
@Suite(.serialized)
struct ContextualBindingArgumentTests {
    /// The container half: a generically recorded container. Selection is what
    /// makes the gap observable — a container that never received the binding
    /// cannot pick a screen, so the unselected tab's content stays on screen.
    private static let containerSource = """
    struct ContentView: View {
        @State private var screen = 2
        @State private var writes = 0

        var body: some View {
            TabView(selection: .init(
                get: { screen },
                set: { newScreen in
                    writes += 1
                    screen = newScreen
                })
            ) {
                Tab(value: 1) {
                    Text("content-one")
                } label: {
                    Text("label-one")
                }
                Tab(value: 2) {
                    Text("content-two")
                } label: {
                    Text("label-two")
                }
            }
            Text("writes-\\(writes)")
        }
    }
    """

    @Test func aContextualBindingArgumentSelectsItsContainer() async throws {
        let before = try await LiveCheckSupport.renderedStrings(
            source: Self.containerSource)
        #expect(before.contains("content-two"),
                Comment(rawValue:
                    "a selection written `.init(get:set:)` must read through "
                        + "its getter; got \(before)"))
        #expect(!before.contains("content-one"),
                Comment(rawValue:
                    "the unselected tab's content must not be on screen — if "
                        + "it is, the argument was filed as configuration "
                        + "rather than as a binding; got \(before)"))

        let after = try await LiveCheckSupport.render(
            source: Self.containerSource, afterActions: 1,
            targeting: .renderingText("label-one"))
        #expect(after.strings.contains("content-one"),
                Comment(rawValue:
                    "selecting through a contextual binding must land on that "
                        + "tab; got \(after.strings) among "
                        + "\(after.actionTargets)"))
        #expect(!after.strings.contains("content-two"),
                Comment(rawValue: "got \(after.strings)"))
        // The write went through the program's own setter, not around it.
        #expect(after.strings.contains("writes-1"),
                Comment(rawValue:
                    "the contextual binding's set() must run exactly once; got "
                        + "\(after.strings)"))
    }

    /// The primitive half: controls whose bindings are recorded by name rather
    /// than by the generic recorder take the same spelling.
    private static let controlSource = """
    struct ContentView: View {
        @State private var draft = "typed"
        @State private var writes = 0

        var body: some View {
            TextField("label", text: .init(
                get: { draft },
                set: { newDraft in
                    writes += 1
                    draft = newDraft
                })
            )
            Text("draft-\\(draft)")
            Text("writes-\\(writes)")
        }
    }
    """

    @Test @MainActor func aControlReadsAndWritesThroughAContextualBinding()
        throws
    {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: Self.controlSource)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let root) = try interpreter.instantiate(
            symbol, with: CallArguments()) else {
            throw RuntimeError(message: "expected an instance")
        }
        let tree = try TraceRegistry.node(interpreter.evaluateBody(of: root))
        let field = try #require(tree.findAll("TextField").first)
        let text = try #require(
            field.bindings["text"],
            "the control must receive the binding, not record it as config")
        #expect(text.box.value.stringValue == "typed")

        text.box.value = .native("edited")
        let after = try TraceRegistry.node(interpreter.evaluateBody(of: root))
        let strings = after.findAll("Text").flatMap(\.args)
        #expect(strings.contains("draft-edited"),
                Comment(rawValue:
                    "a write must reach the state through set(); got \(strings)"))
        #expect(strings.contains("writes-1"),
                Comment(rawValue:
                    "set() must run exactly once; got \(strings)"))
    }
}
