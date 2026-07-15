import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Task cancellation runtime")
struct TaskCancellationRuntimeTests {
    @Test
    func cancellationAfterCompletionPreservesSuccessfulOutcome() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-cancellation-after-completion.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait taskCancellationAfterCompletionProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "active,cancelled,value,value")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func terminalCancellationChangesOnlyCancellationState() throws {
        let runtime = CooperativeConcurrencyRuntime()
        let session = runtime.createSession()
        let record = runtime.createTask(
            sessionID: session,
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .cooperativeDefault,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        let handle = RuntimeTaskHandle(runtime: runtime, record: record)
        #expect(handle.begin())
        handle.succeed(with: .native("value"))
        runtime.release(handle.id)

        handle.cancel()

        #expect(handle.state == .succeeded)
        #expect(handle.isCompleted)
        #expect(handle.isCancelled)
        #expect(handle.cancellation.sources == [.taskHandle])
        #expect(handle.cancellation.requestSequence != nil)
        #expect(!handle.cancellation.isObserved)
        guard case .success(let value, let type)? = handle.outcome else {
            Issue.record("late cancellation changed the successful outcome")
            return
        }
        #expect(value.stringValue == "value")
        #expect(type == "String")
        #expect(runtime.activeRecordCount == 0)
    }

    @Test
    func structuredChildCreatedByCancelledOwnerInheritsCancellation() {
        let runtime = CooperativeConcurrencyRuntime()
        let session = runtime.createSession()
        let owner = runtime.createTask(
            sessionID: session,
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .mainActor,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        runtime.requestCancellation(owner, source: .taskHandle)

        let child = runtime.createTask(
            sessionID: session,
            kind: .asyncLet,
            parent: owner.id,
            priority: .medium,
            executorPreference: .mainActor,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        let unstructured = runtime.createTask(
            sessionID: session,
            kind: .unstructured,
            parent: owner.id,
            priority: .medium,
            executorPreference: .mainActor,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)

        #expect(owner.structuredChildren == [child.id])
        #expect(child.cancellation.sources == [.structuredParent])
        #expect(child.cancellation.requestSequence != nil)
        #expect(unstructured.cancellation.sources.isEmpty)
    }

    @Test
    func optionalTryCatchesCancellationFromSuspendingOperation() async throws {
        let interpreter = Interpreter()
        let value = try await interpreter.runAsync(source: """
        @MainActor
        var optionalTrySleepStarted = false

        let worker = Task {
            optionalTrySleepStarted = true
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled {
                return "continued-cancelled"
            }
            return "continued-active"
        }
        while !optionalTrySleepStarted {
            await Task.yield()
        }
        worker.cancel()
        await worker.value
        """)

        #expect(value.stringValue == "continued-cancelled")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func cancellationBeforeStartStillRunsTheTaskBody() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-cancellation-before-start.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskCancellationBeforeStartProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)
        guard case .instance(let recorder) = value else {
            Issue.record("expected before-start cancellation recorder")
            return
        }
        let taskValue = try #require(
            recorder.box(for: "task")?.value.unwrappedOptionalOrSelf)
        let task = try #require(taskValue.hostPayload as? RuntimeTaskHandle)

        #expect(recorder.box(for: "bodyStarted")?.value.boolValue == true)
        #expect(recorder.box(for: "bodyState")?.value.stringValue
            == "body-cancelled")
        #expect(recorder.box(for: "handleWasCancelled")?.value.boolValue
            == true)
        #expect(task.state == .succeeded)
        #expect(task.result?.stringValue == "body-cancelled")
        #expect(task.isCancelled)
        #expect(task.cancellation.sources == [.taskHandle])
        let requestSequence = try #require(
            task.cancellation.requestSequence)
        let observationSequence = try #require(
            task.cancellation.observationSequence)
        #expect(requestSequence < observationSequence)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func cancellingAValueWaiterDoesNotCancelItsTarget() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-value-waiter-cancellation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskValueWaiterCancellationProbe()\n"
        let interpreter = Interpreter()
        interpreter.globals.define("parityYield", .hostFunction(HostFunction(
            name: "parityYield",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let value = try await interpreter.runAsync(source: source)
        guard case .instance(let recorder) = value else {
            Issue.record("expected waiter-cancellation recorder")
            return
        }

        func handle(_ name: String) throws -> RuntimeTaskHandle {
            let value = try #require(
                recorder.box(for: name)?.value.unwrappedOptionalOrSelf)
            return try #require(value.hostPayload as? RuntimeTaskHandle)
        }

        let target = try handle("target")
        let waiter = try handle("waiter")
        #expect(recorder.box(for: "result")?.value.stringValue
            == "target-active,waiter-cancelled")
        #expect(recorder.box(for: "handleWasCancelled")?.value.boolValue == true)
        #expect(target.state == .succeeded)
        #expect(target.result?.stringValue == "target-active")
        #expect(!target.isCancelled)
        #expect(waiter.state == .succeeded)
        #expect(waiter.result?.stringValue
            == "target-active,waiter-cancelled")
        #expect(waiter.isCancelled)
        #expect(waiter.cancellation.sources == [.taskHandle])
        #expect(waiter.cancellation.isObserved)
        let requestSequence = try #require(
            waiter.cancellation.requestSequence)
        let observationSequence = try #require(
            waiter.cancellation.observationSequence)
        #expect(requestSequence < observationSequence)
        #expect(target.waiterCount == 0)
        #expect(waiter.waitingOnTaskIDs.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
