import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The acceptance gate: @State mutation through Button actions, observed
/// across body re-evaluations — headless, via the trace registry.
@Suite struct CounterStateTests {
    private let source = """
    struct ContentView: View {
        @State var count = 0

        var body: some View {
            VStack {
                Text("Count: \\(count)")
                Button("+") {
                    count += 1
                }
                Button("-") {
                    count -= 1
                }
            }
        }
    }
    """

    @Test func buttonActionsMutateStateAcrossBodyEvaluations() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }

        func countText() throws -> String? {
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            return body.findAll("Text").first?.args.first
        }
        func button(_ title: String) throws -> ClosureValue {
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            let node = try #require(body.findAll("Button").first { $0.args.first == title })
            return try #require(node.actions["action"])
        }

        #expect(try countText() == "Count: 0")

        // The state box change hook fires exactly once per mutation — this is
        // what the SwiftUI bridge listens to for re-rendering.
        var changes = 0
        let box = try #require(instance.stateBoxes["count"])
        box.onChange = { changes += 1 }

        _ = try interpreter.callClosure(try button("+"), arguments: [])
        #expect(changes == 1)
        #expect(try countText() == "Count: 1")

        _ = try interpreter.callClosure(try button("-"), arguments: [])
        _ = try interpreter.callClosure(try button("-"), arguments: [])
        #expect(changes == 3)
        #expect(try countText() == "Count: -1")
    }

    @Test func stateSurvivesInstanceRecreationViaAdoptedBoxes() throws {
        // Mimics what StateStore.adopt does across parent re-renders: a fresh
        // instance adopts the persisted box and sees the mutated value.
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())

        guard case .instance(let first) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        let body = try TraceRegistry.node(interpreter.evaluateBody(of: first))
        let plus = try #require(body.findAll("Button").first { $0.args.first == "+" })
        _ = try interpreter.callClosure(try #require(plus.actions["action"]), arguments: [])

        guard case .instance(let second) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("expected an instance")
            return
        }
        // Fresh instance starts at 0; adopting the persisted box restores 1.
        second.stateBoxes["count"] = try #require(first.stateBoxes["count"])
        let secondBody = try TraceRegistry.node(interpreter.evaluateBody(of: second))
        #expect(secondBody.findAll("Text").first?.args.first == "Count: 1")
    }
}
