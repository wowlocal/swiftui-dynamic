import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Task completion runtime")
struct TaskCompletionRuntimeTests {
    @Test
    func escapedCompletedHandleReleasesRuntimeOwnership() {
        weak var weakRuntime: CooperativeConcurrencyRuntime?
        weak var weakRecord: RuntimeTaskRecord?
        weak var weakDriver: RuntimeNativeTaskDriver?
        var escapedHandle: RuntimeTaskHandle?

        do {
            let runtime = CooperativeConcurrencyRuntime()
            weakRuntime = runtime
            let entry = runtime.createEntry(kind: .test)
            let record = runtime.createTask(
                entry: entry,
                kind: .unstructured,
                parent: nil,
                priority: .medium,
                executorPreference: .cooperativeDefault,
                taskLocals: RuntimeTaskLocalStorage(),
                name: "released-name")
            weakRecord = record
            #expect(record.name == "released-name")
            let handle = RuntimeTaskHandle(runtime: runtime, record: record)
            handle.attach(Task {})
            weakDriver = record.nativeDriver
            #expect(handle.begin())
            handle.succeed(with: .native("value"))
            runtime.release(handle.id)
            escapedHandle = handle
        }

        #expect(escapedHandle?.state == .succeeded)
        #expect(escapedHandle?.result?.stringValue == "value")
        #expect(weakDriver == nil)
        #expect(weakRecord == nil)
        #expect(weakRuntime == nil)
    }

    @Test
    func taskValueWaitRecordsFirstClassAwaitingTaskSuspension() async throws {
        let interpreter = Interpreter()
        var targetGateOpen = false
        var observedWaiterState: RuntimeTaskState?
        var observedSuspension: RuntimeSuspension?
        var observedTargetWaiters: Set<RuntimeTaskID> = []
        var observedWaiterDependencies: Set<RuntimeTaskID> = []

        interpreter.globals.define(
            "waitForTaskValueSuspensionGate",
            .hostFunction(HostFunction(
                name: "waitForTaskValueSuspensionGate",
                asyncInvoke: { _, _ in
                    while !targetGateOpen { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "observeTaskValueSuspension",
            .hostFunction(HostFunction(
                name: "observeTaskValueSuspension",
                asyncInvoke: { _, _ in
                    while true {
                        guard case .host(let targetPayload)? =
                                interpreter.globals.lookup("suspensionTarget"),
                              let target = targetPayload as? RuntimeTaskHandle,
                              case .host(let waiterPayload)? =
                                interpreter.globals.lookup("suspensionWaiter"),
                              let waiter = waiterPayload as? RuntimeTaskHandle,
                              target.waiterCount == 1 else {
                            await Task.yield()
                            continue
                        }
                        observedWaiterState = waiter.state
                        observedSuspension = waiter.suspension
                        observedTargetWaiters = target.record.waiters
                        observedWaiterDependencies = waiter.waitingOnTaskIDs
                        targetGateOpen = true
                        return .void
                    }
                })))

        let result = try await interpreter.runAsync(source: """
        let suspensionTarget = Task {
            await waitForTaskValueSuspensionGate()
            return "value"
        }
        let suspensionWaiter = Task {
            await suspensionTarget.value
        }
        await observeTaskValueSuspension()
        _ = await suspensionWaiter.value
        let completedTargetWaiter = Task {
            await suspensionTarget.value
        }
        await completedTargetWaiter.value
        """)

        guard case .host(let targetPayload)? =
                interpreter.globals.lookup("suspensionTarget"),
              let target = targetPayload as? RuntimeTaskHandle,
              case .host(let waiterPayload)? =
                interpreter.globals.lookup("suspensionWaiter"),
              let waiter = waiterPayload as? RuntimeTaskHandle,
              case .host(let completedWaiterPayload)? =
                interpreter.globals.lookup("completedTargetWaiter"),
              let completedWaiter =
                completedWaiterPayload as? RuntimeTaskHandle else {
            Issue.record("expected task-value suspension handles")
            return
        }
        #expect(result.stringValue == "value")
        #expect(observedWaiterState == .waiting)
        #expect(observedSuspension == .awaitingTask(target.id))
        #expect(observedTargetWaiters == [waiter.id])
        #expect(observedWaiterDependencies == [target.id])
        #expect(waiter.state == .succeeded)
        #expect(waiter.suspension == nil)
        #expect(waiter.suspensionHistory == [.awaitingTask(target.id)])
        #expect(completedWaiter.state == .succeeded)
        #expect(completedWaiter.suspensionHistory.isEmpty)
        #expect(target.waiterCount == 0)
        #expect(waiter.waitingOnTaskIDs.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func completedHandlesRetainTypedOutcomesAfterRuntimeRelease() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-completed-handle-reads.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait startTaskCompletedHandleReadProbe()\n"
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
            Issue.record("expected completed-handle recorder")
            return
        }

        func handle(_ name: String) throws -> RuntimeTaskHandle {
            let value = try #require(
                recorder.box(for: name)?.value.unwrappedOptionalOrSelf)
            return try #require(value.hostPayload as? RuntimeTaskHandle)
        }

        let success = try handle("success")
        let failure = try handle("failure")
        #expect(recorder.box(for: "output")?.value.stringValue
            == "value,value,success:value,failure,failure,get-caught")

        #expect(success.state == .succeeded)
        #expect(success.isCompleted)
        #expect(!success.isCancelled)
        guard case .success(let successValue, let successType)? =
                success.outcome else {
            Issue.record("expected retained success outcome")
            return
        }
        #expect(successValue.stringValue == "value")
        #expect(successType == "String")

        #expect(failure.state == .failed)
        #expect(failure.isCompleted)
        #expect(!failure.isCancelled)
        guard case .failure(let failureValue, let failureType)? =
                failure.outcome else {
            Issue.record("expected retained failure outcome")
            return
        }
        #expect(failureType == "TaskCompletedHandleReadError")
        guard case .enumCase(let errorCase) = failureValue else {
            Issue.record("expected retained interpreted error value")
            return
        }
        #expect(errorCase.symbol.name == "TaskCompletedHandleReadError")
        #expect(errorCase.name == "failed")

        #expect(success.waiterCount == 0)
        #expect(failure.waiterCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
