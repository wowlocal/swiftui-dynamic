import Foundation
import Testing
@testable import SwiftInterpreter

private final class CheckedContinuationProducerGate {
    var entered = false
    var isOpen = false
}

@Suite("Checked continuation runtime")
struct CheckedContinuationRuntimeTests {
    @Test func detachedProducerResumesValueAndClosesRuntimeRecord()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/checked-continuation-value-resume.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedContinuationValueResumeProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "41")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount >= 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func throwingValueAndSourceErrorShareRecordCleanup()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-throwing-continuation-value-error.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedThrowingContinuationValueErrorProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "value:23|error:failed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func resultResumeUsesReturningAndThrowingTransitions()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-throwing-continuation-result-resume.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedThrowingContinuationResultResumeProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "value:29|error:failed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func voidResumeUsesSameRecordAndCleanup() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-continuation-void-resume.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedContinuationVoidResumeProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "void-resumed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func delayedResumeOwnsCanonicalSuspensionAndExecutor()
        async throws
    {
        let interpreter = Interpreter()
        let gate = CheckedContinuationProducerGate()
        interpreter.globals.define(
            "waitForContinuationProducerGate",
            .hostFunction(HostFunction(
                name: "waitForContinuationProducerGate",
                asyncInvoke: { _, _ in
                    gate.entered = true
                    while !gate.isOpen { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "checkedContinuationExecutorLane",
            .hostFunction(HostFunction(
                name: "checkedContinuationExecutorLane"
            ) { _, context in
                .native(context.sourceExecutor.isMainActor ? "main" : "worker")
            }))
        let evaluation = Task {
            try await interpreter.runAsync(source: """
                @concurrent
                nonisolated
                func controlledContinuationValue() async -> String {
                    let entered = checkedContinuationExecutorLane()
                    let bodyLane: String = await withCheckedContinuation(
                        isolation: MainActor.shared
                    ) { continuation in
                        let lane = checkedContinuationExecutorLane()
                        Task.detached {
                            await waitForContinuationProducerGate()
                            continuation.resume(returning: lane)
                        }
                    }
                    let resumed = checkedContinuationExecutorLane()
                    return "\\(entered)|\\(bodyLane)|\\(resumed)"
                }

                await controlledContinuationValue()
                """)
        }
        defer {
            gate.isOpen = true
            evaluation.cancel()
        }

        var reachedWait = false
        for _ in 0..<10_000 {
            if gate.entered,
               interpreter.concurrencyRuntime.activeContinuationCount == 1 {
                reachedWait = true
                break
            }
            await Task.yield()
        }
        #expect(reachedWait)
        let continuation = try #require(
            interpreter.concurrencyRuntime.continuations.values.first)
        let owner = try #require(
            interpreter.concurrencyRuntime.records[continuation.ownerTaskID])
        let reason = RuntimeSuspension.waitingForContinuation(continuation.id)
        #expect(owner.state == .waiting)
        #expect(owner.suspension == reason)
        #expect(owner.suspensionHistory.last == reason)
        #expect(continuation.suspensionLease?.reason == reason)
        #expect(continuation.requiredExecutor == .cooperativeDefault)
        #expect(owner.evaluationContext?.currentExecutor == .cooperativeDefault)

        gate.isOpen = true
        let value = try await evaluation.value

        #expect(value.stringValue == "worker|main|worker")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func hostCancellationAbortsWaitAndCleansRegistry() async throws {
        let interpreter = Interpreter()
        let evaluation = Task {
            try await interpreter.runAsync(source: """
                nonisolated func waitForAbandonedContinuation() async -> Int {
                    let value: Int = await withCheckedContinuation(
                        isolation: nil
                    ) { _ in }
                    return value
                }

                await waitForAbandonedContinuation()
                """)
        }

        var reachedWait = false
        for _ in 0..<10_000 {
            if interpreter.concurrencyRuntime.activeContinuationCount == 1 {
                reachedWait = true
                break
            }
            await Task.yield()
        }
        #expect(reachedWait)
        evaluation.cancel()
        do {
            _ = try await evaluation.value
            Issue.record("host cancellation did not abort the interpreter run")
        } catch is CancellationError {
            // Expected infrastructure abort, not a source continuation result.
        }

        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func arbitraryActorIsolationFailsClosedBeforeRecordCreation()
        async throws
    {
        let interpreter = Interpreter()
        do {
            _ = try await interpreter.runAsync(source: """
                actor ContinuationIsolationActor {}

                let isolation = ContinuationIsolationActor()
                await withCheckedContinuation(isolation: isolation) {
                    continuation in
                    continuation.resume(returning: 1)
                }
                """)
            Issue.record(
                "arbitrary actor isolation was silently treated as MainActor")
        } catch {
            #expect(String(describing: error).contains(
                "currently supports only nil or MainActor isolation"))
        }

        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }
}
