import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("AsyncStream runtime")
struct AsyncStreamRuntimeTests {
    @Test func suspendedConsumerResumesAndDrainsRuntime() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-stream-suspended-consumer.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncStreamSuspendedConsumerProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "2:6")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount >= 1)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func unsupportedBufferingPolicyFailsClosed() async throws {
        let interpreter = Interpreter()

        do {
            try await interpreter.runAsync(source: """
                let stream = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(1)) {
                    continuation in
                    continuation.finish()
                }
                var iterator = stream.makeAsyncIterator()
                await iterator.next()
                """)
            Issue.record("unsupported buffering policy was silently accepted")
        } catch let error as RuntimeError {
            #expect(error.message
                == "AsyncStream currently supports only .unbounded buffering")
        }

        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func cancelledConsumerRunsTerminationBeforeReturningNil() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-stream-cancelled-consumer.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncStreamCancelledConsumerProbe()\n"
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

    @Test func finishCallbackIsSynchronousOneShotAndTerminal() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-stream-finish-termination.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncStreamFinishTerminationProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "3:true:true:finished,after-finish:terminated")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func finishResumesEveryIndependentConsumer() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/async-stream-multiple-consumers.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait asyncStreamMultipleConsumersProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "true:true:2")
        #expect(interpreter.concurrencyRuntime.totalAsyncStreamsCreated == 1)
        #expect(interpreter.concurrencyRuntime.asyncStreamSuspensionCount >= 2)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }
}
