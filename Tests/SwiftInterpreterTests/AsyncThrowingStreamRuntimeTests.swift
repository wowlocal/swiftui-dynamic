import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("AsyncThrowingStream runtime")
struct AsyncThrowingStreamRuntimeTests {
    @Test func unverifiedNormalFinishAndBufferingFailClosed() async throws {
        let sources = [
            (source: """
                let stream = AsyncThrowingStream<Int, Error> { continuation in
                    continuation.finish()
                }
                """, diagnostic:
                "AsyncThrowingStream normal finish is not yet supported"),
            (source: """
                let stream = AsyncThrowingStream<Int, Error>(
                    bufferingPolicy: .bufferingNewest(1)
                ) { continuation in
                    continuation.finish(throwing: CancellationError())
                }
                """, diagnostic:
                "AsyncThrowingStream bounded buffering is not yet supported")
        ]

        for item in sources {
            let interpreter = Interpreter()
            do {
                try await interpreter.runAsync(source: item.source)
                Issue.record("unverified AsyncThrowingStream behavior was accepted")
            } catch let error as RuntimeError {
                #expect(error.message == item.diagnostic)
            }
            #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
            #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
            #expect(interpreter.scheduledTasks.isEmpty)
        }
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
}
