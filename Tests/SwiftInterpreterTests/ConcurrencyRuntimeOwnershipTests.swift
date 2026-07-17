import Testing
@testable import SwiftInterpreter

@Suite("Concurrency runtime ownership")
struct ConcurrencyRuntimeOwnershipTests {
    @Test func nativeStackBoundsAreTaskOwnedAndThreadScoped() {
        let runtime = CooperativeConcurrencyRuntime()
        let first = runtime.makeEvaluationTaskContext()
        let second = runtime.makeEvaluationTaskContext()

        first.evaluationStackBounds = EvaluationStackBounds(
            threadID: 41,
            lowerBound: 1,
            size: 2,
            safetyHeadroom: 3)

        #expect(first.evaluationStackBounds?.matches(threadID: 41) == true)
        #expect(first.evaluationStackBounds?.matches(threadID: 42) == false)
        #expect(second.evaluationStackBounds == nil)

        first.removeAllDynamicState()
        #expect(first.evaluationStackBounds == nil)
    }

    @Test func evaluationContextUsesRuntimeIdentityWithoutRetainingFacade() {
        var interpreter: Interpreter? = Interpreter()
        guard let runtime = interpreter?.concurrencyRuntime else {
            Issue.record("interpreter did not create a concurrency runtime")
            return
        }
        weak let releasedInterpreter = interpreter

        let context = runtime.makeEvaluationTaskContext()
        #expect(context.concurrencyRuntime === runtime)

        interpreter = nil
        #expect(releasedInterpreter == nil)
        #expect(context.concurrencyRuntime === runtime)
    }

    @Test func ambientContextIsSelectedByRuntimeIdentity() {
        let first = Interpreter()
        let second = Interpreter()
        let context = first.concurrencyRuntime.makeEvaluationTaskContext()

        let firstObserved = EvaluationTaskContext.$current.withValue(context) {
            first.currentEvaluationTaskContextID
        }
        let secondObserved = EvaluationTaskContext.$current.withValue(context) {
            second.currentEvaluationTaskContextID
        }

        #expect(firstObserved == context.id)
        #expect(secondObserved == 0)
    }

    @Test func runtimeAllocatesUniqueEvaluationContextIdentities() {
        let interpreter = Interpreter()
        let runtime = interpreter.concurrencyRuntime

        let first = runtime.makeEvaluationTaskContext()
        let second = runtime.makeEvaluationTaskContext()

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
