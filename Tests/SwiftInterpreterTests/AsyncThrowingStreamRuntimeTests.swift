import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("AsyncThrowingStream runtime")
struct AsyncThrowingStreamRuntimeTests {
    @Test func unverifiedBufferingFailsClosed() async throws {
        let interpreter = Interpreter()
        do {
            try await interpreter.runAsync(source: """
                let stream = AsyncThrowingStream<Int, Error>(
                    bufferingPolicy: .bufferingNewest(1)
                ) { continuation in
                    continuation.finish(throwing: CancellationError())
                }
                """)
            Issue.record("unverified AsyncThrowingStream buffering was accepted")
        } catch let error as RuntimeError {
            #expect(error.message
                == "AsyncThrowingStream bounded buffering is not yet supported")
        }
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
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
}
