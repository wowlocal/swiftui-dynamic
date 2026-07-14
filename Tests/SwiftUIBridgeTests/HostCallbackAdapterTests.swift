import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

@Suite(.serialized)
struct HostCallbackAdapterTests {
    @Test func synchronousActionStartsRuntimeBackedSourceTasks() async throws {
        RenderDiagnostics.reset()
        let interpreter = Interpreter()
        let action = try interpreter.run(source: """
        @MainActor
        final class CallbackState {
            var phase = "idle"

            func start() {
                phase = "started"
                Task.detached {
                    let total = await withTaskGroup(of: Int.self) { group in
                        group.addTask { 1 }
                        group.addTask { 2 }
                        let first = await group.next() ?? 0
                        let second = await group.next() ?? 0
                        return first + second
                    }
                    await self.finish(total)
                }
            }

            func finish(_ total: Int) {
                phase = "done-\\(total)"
            }
        }

        let callbackState = CallbackState()

        func makeAction() -> () -> Void {
            { callbackState.start() }
        }

        makeAction()
        """)
        let closure = try #require(action.closureValue)
        guard case .instance(let state)? = interpreter.globals.lookup(
            "callbackState") else {
            Issue.record("callback state missing")
            return
        }
        let callback = InterpretedHostCallback(
            closure: closure,
            context: interpreter,
            diagnosticContext: "Button action")

        callback.call()

        #expect(state.box(for: "phase")?.value.stringValue == "started")
        for _ in 0..<1_000
        where state.box(for: "phase")?.value.stringValue != "done-3" {
            await Task.yield()
        }
        #expect(state.box(for: "phase")?.value.stringValue == "done-3")
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    @Test func callbackFailureIsObservable() throws {
        RenderDiagnostics.reset()
        let interpreter = Interpreter()
        let action = try interpreter.run(source: """
        func makeFailingAction() -> () -> Void {
            { missingCallbackFunction() }
        }
        makeFailingAction()
        """)
        let closure = try #require(action.closureValue)
        let callback = InterpretedHostCallback(
            closure: closure,
            context: interpreter,
            diagnosticContext: "Button action")

        callback.call()

        #expect(RenderDiagnostics.errors.count == 1)
        #expect(RenderDiagnostics.errors.first?.view == "Button action")
        #expect(RenderDiagnostics.errors.first?.error.message.contains(
            "missingCallbackFunction") == true)
    }

    @Test func callbackPreservesConcurrentAndMainActorExecutorHops() async throws {
        RenderDiagnostics.reset()
        let interpreter = Interpreter(registry: ViewRegistry())
        let action = try interpreter.run(source: """
        @MainActor
        final class CallbackExecutorState {
            var lanes = "idle"

            func start() {
                Task.detached {
                    await self.work()
                }
            }

            @concurrent nonisolated
            func work() async {
                let entered = lane()
                await Task.yield()
                let resumed = lane()
                await self.finish(entered + ":" + resumed)
            }

            nonisolated func lane() -> String {
                Thread.isMainThread ? "main" : "worker"
            }

            func finish(_ workerLanes: String) {
                lanes = workerLanes + ":" + lane()
            }
        }

        let callbackExecutorState = CallbackExecutorState()

        func makeAction() -> () -> Void {
            { callbackExecutorState.start() }
        }

        makeAction()
        """)
        let closure = try #require(action.closureValue)
        guard case .instance(let state)? = interpreter.globals.lookup(
            "callbackExecutorState") else {
            Issue.record("callback executor state missing")
            return
        }
        let callback = InterpretedHostCallback(
            closure: closure,
            context: interpreter,
            diagnosticContext: "Button action")

        callback.call()

        for _ in 0..<1_000
        where state.box(for: "lanes")?.value.stringValue == "idle" {
            await Task.yield()
        }
        #expect(state.box(for: "lanes")?.value.stringValue
            == "worker:worker:main")
        #expect(RenderDiagnostics.errors.isEmpty)
    }
}
