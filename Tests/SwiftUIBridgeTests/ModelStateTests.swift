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

        // A cancellable only keeps its subscription alive while retained.
        // Optimized Swift may release an otherwise-unused local after its
        // last access rather than at the closing brace.
        withExtendedLifetime(subscriptions) {}
    }

    @Test func wrapperBackingStorageInCustomInits() throws {
        let source = """
        struct Stepper2: View {
            @Binding var value: Int
            @State var label: String
            var step = 1

            init(value: Binding<Int>, step: Int) {
                self._value = value
                self._label = State(initialValue: "step \\(step)")
                self.step = step
            }

            var body: some View {
                Button(label) {
                    value += step
                }
            }
        }

        struct ContentView: View {
            @State var total = 10

            var body: some View {
                VStack {
                    Text("total \\(total)")
                    Stepper2(value: $total, step: 5)
                }
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }

        var actions: [ClosureValue] = []
        let root = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        _ = try HeadlessVerifier.deepRender(interpreter, root, actions: &actions)

        // The child's button label came from State(initialValue:), and its
        // action writes THROUGH the assigned binding storage to the parent.
        _ = try interpreter.callClosure(try #require(actions.first), arguments: [])
        let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(rerendered.findAll("Text").first?.args.first == "total 15")
    }

    @Test func implicitMembersAdoptComparisonType() throws {
        let source = """
        let a: CGSize = .zero
        let moved = CGSize(width: 3.0, height: 0.0)
        "\\(a == .zero) \\(.zero == a) \\(moved != .zero)"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        #expect(try interpreter.run(source: source).stringValue == "true true true")
    }

    @Test func cgNumericTypeContext() throws {
        let source = """
        struct ContentView: View {
            @State var dragOffset: CGSize = .zero

            var body: some View {
                Text("x")
                    .offset(x: dragOffset.width + CGFloat(10))
            }
        }
        let p: CGPoint = .zero
        let width = CGFloat(2.5) * 2.0
        "\\(p.y) \\(width)"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        #expect(try interpreter.run(source: source).stringValue == "0.0 5.0")

        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        _ = try interpreter.evaluateBody(of: instance) // offset math must evaluate
    }

    @Test func preferenceKeyPatternTraces() throws {
        // The PreferenceKey idiom: Type.self flows into preference modifiers,
        // which trace mode records without executing.
        let source = """
        struct OffsetKey {
            static var defaultValue = 0.0
        }

        struct ContentView: View {
            var body: some View {
                Text("row")
                    .preference(key: OffsetKey.self, value: 12.0)
                    .onPreferenceChange(OffsetKey.self) { value in
                    }
            }
        }
        """
        _ = try HeadlessVerifier.verify(source: source)
    }

    @Test func stateLikeWrappersProjectAndBind() throws {
        let source = """
        struct ContentView: View {
            @AppStorage("firstTime") var isFirstTime = true
            @GestureState var dragOffset = 0.0

            var body: some View {
                VStack {
                    Toggle("Intro", isOn: $isFirstTime)
                    Text(isFirstTime ? "welcome" : "back")
                    Text("drag \\(dragOffset)")
                }
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.findAll("Toggle").first?.bindings["isOn"] != nil)
        #expect(body.findAll("Text").first?.args.first == "welcome")

        // Binding writes re-render like @State.
        try #require(body.findAll("Toggle").first?.bindings["isOn"]).box.value = .native(false)
        let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(rerendered.findAll("Text").first?.args.first == "back")
    }

    @Test func nestedStateLikeWrapperDefaultInitializesSingleton() throws {
        let source = """
        final class Settings {
            final class Storage {
                @AppStorage("native_parity_nested_default") var compact: Bool = true
                init() {}
            }

            let storage = Storage()
            var compact: Bool
            static let shared = Settings()

            private init() {
                compact = storage.compact
            }
        }

        Settings.shared.compact ? 20 : 8
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.intValue == 20)
    }

    @Test func applicationWindowChain() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        let bottom = try interpreter.run(
            source: "UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? -1.0"
        )
        #expect(bottom.doubleValue == 0.0)
    }

    @Test func timerPublisherPlumbing() throws {
        // The publish/autoconnect chain yields the box either way…
        let interpreter = Interpreter(registry: TraceRegistry())
        let box = try interpreter.run(source: "Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()")
        if case .host(let any) = box {
            #expect(any is TimerPublisherBox)
        } else {
            Issue.record("expected a TimerPublisherBox")
        }
        // …and the real registry renders the .onReceive pattern.
        let real = Interpreter(registry: ViewRegistry())
        _ = try real.run(source: """
        Text("t").onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
        }
        """)
    }

    @Test func representablesRenderInert() throws {
        let source = """
        struct Chrome: UIViewRepresentable {
            var tag = 0
            func makeUIView(context: Context) -> UIView {
                UIView()
            }
            func updateUIView(_ view: UIView, context: Context) {
            }
        }
        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("above")
                    Chrome(tag: 1)
                }
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.children.map(\.kind) == ["Text", "Representable:Chrome"])
    }

    @Test func appearanceProxiesAreInert() throws {
        let source = """
        UITabBar.appearance().isHidden = true
        UITableView.appearance().backgroundColor = .clear
        UINavigationBar.appearance().standardAppearance.configureWithOpaqueBackground()
        7
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        #expect(try interpreter.run(source: source).intValue == 7)
    }

    @Test func dateFoundationPipeline() throws {
        // The real-project date pipeline: random amounts, Calendar math on
        // .now, format styles — all backed by real Foundation.
        let source = """
        struct Entry {
            var amount: Double
            var date: Date

            init(daysAgo: Int) {
                self.amount = .random(in: 10...99)
                self.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
            }
        }
        let e = Entry(daysAgo: 3)
        let text = e.date.formatted(date: .numeric, time: .shortened)
        let inRange = e.amount >= 10.0 && e.amount <= 99.0
        "\\(text.isEmpty) \\(inRange) \\(e.date.timeIntervalSince1970 < Date().timeIntervalSince1970)"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        #expect(try interpreter.run(source: source).stringValue == "false true true")
    }

    @Test func dateFormatterHostObject() throws {
        let source = """
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: Date())
        let readBack = formatter.dateFormat
        let parsed = formatter.date(from: "2001")
        "\\(year.count) \\(readBack) \\(parsed == nil ? "no" : "yes")"
        """
        let registry = TraceRegistry()
        let firstConstructor = try #require(registry.constructor(named: "DateFormatter"))
        let secondConstructor = try #require(registry.constructor(named: "DateFormatter"))
        #expect(firstConstructor === secondConstructor)
        #expect(firstConstructor.signature?.declaration == "init DateFormatter()")
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: source)
        #expect(result.stringValue == "4 yyyy yes")
    }

    @Test func hostTypeExtensions() throws {
        let source = """
        extension View {
            func screenWidth() -> Double {
                return 390.0
            }

            var halfWidth: Double {
                screenWidth() / 2
            }
        }

        extension String {
            func shout() -> String {
                self.uppercased() + "!"
            }
        }

        struct ContentView: View {
            var body: some View {
                Text("w=\\(screenWidth()) h=\\(halfWidth) \\("hi".shout())")
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.findAll("Text").first?.args.first == "w=390.0 h=195.0 HI!")

        // Member-call form on a view value.
        let width = try interpreter.run(source: #"Text("x").screenWidth()"#)
        #expect(width.doubleValue == 390.0)
    }

    @Test func environmentValuesInjectAndCompare() throws {
        let source = """
        struct ContentView: View {
            @Environment(\\.colorScheme) var scheme
            @Environment(\\.dismiss) var dismiss

            var body: some View {
                VStack {
                    Text(scheme == .dark ? "dark" : "light")
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }

        // Headless defaults: light + no-op dismiss.
        interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
        var body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.findAll("Text").first?.args.first == "light")
        _ = try interpreter.callClosure(
            try #require(body.findAll("Button").first?.actions["action"]), arguments: []
        ) // dismiss() must be callable

        // Overriding (what InterpretedView does with real environment reads).
        interpreter.injectEnvironmentValues(into: instance, values: ["colorScheme": .implicitMember("dark")])
        body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.findAll("Text").first?.args.first == "dark")
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
