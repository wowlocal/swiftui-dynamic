import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("AsyncThrowingStream runtime")
struct AsyncThrowingStreamRuntimeTests {
    @Test func unverifiedBufferingPoliciesFailClosed() async throws {
        for policy in ["bufferingOldest(1)", "bufferingNewest(0)"] {
            let interpreter = Interpreter()
            do {
                try await interpreter.runAsync(source: """
                    let stream = AsyncThrowingStream<Int, Error>(
                        bufferingPolicy: .\(policy)
                    ) { continuation in
                        continuation.finish(throwing: CancellationError())
                    }
                    """)
                Issue.record(
                    "unverified AsyncThrowingStream .\(policy) was accepted")
            } catch let error as RuntimeError {
                #expect(error.message
                    == "AsyncThrowingStream buffering policy is not yet supported")
            }
            #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
            #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
            #expect(interpreter.scheduledTasks.isEmpty)
        }
    }

    @Test func bufferingNewestEvictsOldestValuesWithExactResults()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-throwing-stream-buffering-newest.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncThrowingStreamBufferingNewestProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "enqueued(remaining: 1)"
            + "|enqueued(remaining: 0)|dropped(1)|dropped(2)"
            + "=>3,4,true")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func suspendedConsumerReceivesValueThenExactSourceFailure()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-throwing-stream-suspended-failure.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncThrowingStreamSuspendedFailureProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "1:2:caught")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount >= 1)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func normalFinishCallbackIsSynchronousOneShotAndTerminal()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-throwing-stream-finish-termination.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncThrowingStreamFinishTerminationProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "3:true:true:finished(nil),after-finish:terminated")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func failureFinishCallbackCarriesExactSourceErrorBeforeReturn()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-throwing-stream-failure-termination.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncThrowingStreamFailureTerminationProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "5:caught:finished-error,after-finish:terminated")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func cancelledConsumerResumesNilAfterSynchronousTerminationCallback()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-throwing-stream-cancelled-consumer.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncThrowingStreamCancelledConsumerProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "true:true:cancelled:cancelled")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount >= 1)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }
}
