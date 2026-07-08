import Combine
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The MVVM loop headless: @StateObject models persist across view
/// recreation, model mutation re-renders through the StateStore, and
/// `$store.field` projects real bindings onto model boxes.
@Suite struct ModelStateTests {
    private let source = """
    class TodoStore: ObservableObject {
        @Published var titles: [String] = []
        @Published var draft = ""

        func add() {
            guard !draft.isEmpty else {
                return
            }
            titles.append(draft)
            draft = ""
        }
    }

    struct ContentView: View {
        @StateObject var store = TodoStore()

        var body: some View {
            VStack {
                TextField("New", text: $store.draft)
                Button("Add") {
                    store.add()
                }
                Text("count: \\(store.titles.count)")
            }
        }
    }
    """

    private func instantiateRoot(_ interpreter: Interpreter) throws -> Instance {
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            throw RuntimeError(message: "expected an instance")
        }
        return instance
    }

    @Test func stateObjectPersistsAcrossViewRecreationAndNotifies() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let store = StateStore()

        // First structural identity: fresh view, fresh model.
        let first = try instantiateRoot(interpreter)
        store.adopt(into: first)

        var renders = 0
        var subscriptions = Set<AnyCancellable>()
        store.objectWillChange.sink { renders += 1 }.store(in: &subscriptions)

        // Type into the field via its binding, then click Add.
        let tree1 = try TraceRegistry.node(interpreter.evaluateBody(of: first))
        try #require(tree1.findAll("TextField").first?.bindings["text"]).box.value = .native("write tests")
        #expect(renders == 1) // @Published draft change re-rendered

        let add = try #require(tree1.findAll("Button").first?.actions["action"])
        _ = try interpreter.callClosure(add, arguments: [])
        #expect(renders >= 2) // append + draft reset both notified

        // Parent re-render: fresh view instance adopts the SAME model.
        let second = try instantiateRoot(interpreter)
        store.adopt(into: second)
        let tree2 = try TraceRegistry.node(interpreter.evaluateBody(of: second))
        #expect(tree2.findAll("Text").first?.args.first == "count: 1")
    }

    @Test func dispatchQueueMainAsyncRunsInterpretedClosures() async throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: """
        class Model: ObservableObject {
            @Published var n = 0
            func bumpLater() {
                DispatchQueue.main.async {
                    n += 1
                }
            }
        }
        let m = Model()
        m.bumpLater()
        """)
        guard case .instance(let model)? = interpreter.globals.lookup("m") else {
            Issue.record("expected a model")
            return
        }
        #expect(model.box(for: "n")?.value.intValue == 0) // deferred, not sync
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.box(for: "n")?.value.intValue == 1)
    }

    @Test func observedObjectSharesModelBetweenViews() throws {
        let shared = """
        class Counter: ObservableObject {
            @Published var n = 0
        }

        struct Display: View {
            @ObservedObject var counter: Counter

            var body: some View {
                Text("n=\\(counter.n)")
            }
        }

        struct ContentView: View {
            @StateObject var counter = Counter()

            var body: some View {
                VStack {
                    Display(counter: counter)
                    Button("+") {
                        counter.n += 1
                    }
                }
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: shared)
        let root = try instantiateRoot(interpreter)

        let tree = try TraceRegistry.node(interpreter.evaluateBody(of: root))
        _ = try interpreter.callClosure(try #require(tree.findAll("Button").first?.actions["action"]), arguments: [])

        // The child re-renders with the shared, mutated model.
        let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: root))
        let child = try #require(rerendered.findAll("View:Display").first?.instance)
        let childBody = try TraceRegistry.node(interpreter.evaluateBody(of: child))
        #expect(childBody.findAll("Text").first?.args.first == "n=1")
    }
}
