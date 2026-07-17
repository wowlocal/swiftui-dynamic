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
        let evaluation = Task {
            try await interpreter.runAsync(source: """
                nonisolated func controlledContinuationValue() async -> Int {
                    let value: Int = await withCheckedContinuation(
                        isolation: nil
                    ) { continuation in
                        Task.detached {
                            await waitForContinuationProducerGate()
                            continuation.resume(returning: 17)
                        }
                    }
                    return value
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
        #expect(owner.evaluationContext?.currentExecutor
            == continuation.requiredExecutor)

        gate.isOpen = true
        let value = try await evaluation.value

        #expect(value.intValue == 17)
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
}
