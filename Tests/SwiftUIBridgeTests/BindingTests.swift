import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Realm's observation wrappers project like their SwiftUI cousins
/// (SwiftUIRealm, iteration 192): `@ObservedRealmObject var task` gives
/// `$task.member.wrappedValue = …` member bindings (@Bindable-shaped),
/// `@StateRealmObject` owns its object like @StateObject.
@Suite struct RealmWrapperProjectionTests {
    @Test func observedRealmObjectProjectsMemberBindings() throws {
        let source = """
        enum TaskStatus: String {
            case pending, missed, completed
        }

        final class TaskItem: ObservableObject {
            @Published var title = "write tests"
            @Published var taskStatus: TaskStatus = .pending
        }

        struct TaskRow: View {
            @ObservedRealmObject var task: TaskItem

            var body: some View {
                VStack {
                    Text(task.title)
                    Button("Mark Missed") {
                        $task.taskStatus.wrappedValue = .missed
                    }
                    Text(task.taskStatus.rawValue)
                }
            }
        }

        struct ContentView: View {
            @StateRealmObject var task = TaskItem()

            var body: some View {
                TaskRow(task: task)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
        #expect(report.actionsInvoked == 1, "the Mark Missed action must click through the projection")
    }
}

/// `$state` projections: writes through the bound box must be visible on the
/// next body evaluation and fire the state change hook — the same loop
/// Toggle/Slider/TextField drive through their real `Binding` setters.
@Suite struct BindingTests {
    private let source = """
    struct ContentView: View {
        @State var name = ""
        @State var isOn = false
        @State var volume = 5

        var body: some View {
            VStack {
                TextField("Name", text: $name)
                Toggle("Enabled", isOn: $isOn)
                Slider(value: $volume, in: 0...10)
                Text("\\(name): \\(isOn ? "on" : "off") at \\(volume)")
            }
        }
    }
    """

    private func makeInstance() throws -> (Interpreter, Instance) {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            throw RuntimeError(message: "expected an instance")
        }
        return (interpreter, instance)
    }

    @Test func controlsReceiveBindingsToStateBoxes() throws {
        let (interpreter, instance) = try makeInstance()
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))

        let textField = try #require(body.findAll("TextField").first)
        let toggle = try #require(body.findAll("Toggle").first)
        let slider = try #require(body.findAll("Slider").first)

        #expect(textField.bindings["text"] != nil)
        #expect(toggle.bindings["isOn"] != nil)
        #expect(slider.bindings["value"] != nil)
        // The stub wraps the instance's actual state box, not a copy.
        #expect(textField.bindings["text"]?.box === instance.stateBoxes["name"])
    }

    @Test func bindingWritesShowUpInNextBodyEvaluation() throws {
        let (interpreter, instance) = try makeInstance()

        func summary() throws -> String? {
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            return body.findAll("Text").first?.args.first
        }
        #expect(try summary() == ": off at 5")

        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        var changes = 0
        instance.stateBoxes["isOn"]?.onChange = { changes += 1 }

        try #require(body.findAll("TextField").first?.bindings["text"]).box.value = .native("Ada")
        try #require(body.findAll("Toggle").first?.bindings["isOn"]).box.value = .native(true)
        try #require(body.findAll("Slider").first?.bindings["value"]).box.value = .native(9)

        #expect(changes == 1)
        #expect(try summary() == "Ada: on at 9")
    }

    @Test func realRegistryRendersBindingControls() throws {
        let outcome = InterpreterHost().render(source: source)
        if case .failure(let error) = outcome {
            Issue.record("render failed: \(error)")
        }
    }

    @Test func wrappedValueReadsAndWritesThroughTheBox() throws {
        let source = """
        struct ContentView: View {
            @State var n = 1

            var body: some View {
                VStack {
                    Text("value \\($n.wrappedValue)")
                    Button("bump") {
                        $n.wrappedValue += 4
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
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(body.findAll("Text").first?.args.first == "value 1")
        _ = try interpreter.callClosure(
            try #require(body.findAll("Button").first?.actions["action"]), arguments: []
        )
        let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        #expect(rerendered.findAll("Text").first?.args.first == "value 5")
    }

    @Test func projectionWithoutStatePropertyIsLocatedError() throws {
        // Body evaluation is lazy (InterpreterHost.render only wraps the root),
        // so evaluate the body directly to observe the located error.
        let bad = """
        struct ContentView: View {
            var body: some View {
                Toggle("x", isOn: $missing)
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: bad)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        do {
            _ = try interpreter.evaluateBody(of: instance)
            Issue.record("expected an error")
        } catch let error as RuntimeError {
            #expect(error.message.contains("@State"))
            #expect(error.line == 3)
        }
    }
}
