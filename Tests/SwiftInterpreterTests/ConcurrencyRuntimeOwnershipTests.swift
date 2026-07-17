import Testing
@testable import SwiftInterpreter

@Suite("Concurrency runtime ownership")
struct ConcurrencyRuntimeOwnershipTests {
    @Test func runtimeAllocatesUniqueEvaluationContextIdentities() {
        let interpreter = Interpreter()
        let runtime = interpreter.concurrencyRuntime

        let first = runtime.makeEvaluationTaskContext(
            interpreter: interpreter)
        let second = runtime.makeEvaluationTaskContext(
            interpreter: interpreter)

        #expect(first.id != 0)
        #expect(second.id != 0)
        #expect(first.id != second.id)
    }

    @Test func runtimeRetainsScheduledHandleUntilCanonicalRelease() throws {
        let runtime = CooperativeConcurrencyRuntime()
        let entry = runtime.createEntry(kind: .compatibilityTask)
        let record = runtime.createTask(
            entry: entry,
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .cooperativeDefault,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        var handle: RuntimeTaskHandle? = RuntimeTaskHandle(
            runtime: runtime, record: record)
        weak let retainedHandle = handle

        runtime.retainScheduledTask(try #require(handle))
        #expect(runtime.scheduledTaskHandles.count == 1)
        #expect(runtime.firstScheduledTask(in: entry.id) === handle)

        handle = nil
        #expect(retainedHandle != nil)
        do {
            let owned = try #require(runtime.scheduledTaskHandles.first)
            runtime.releaseScheduledTask(owned)
            runtime.releaseScheduledTask(owned)
        }

        #expect(runtime.scheduledTaskHandles.isEmpty)
        #expect(runtime.activeRecordCount == 0)
        #expect(retainedHandle == nil)
    }
}
