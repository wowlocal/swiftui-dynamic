import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Unsafe continuation runtime")
struct UnsafeContinuationRuntimeTests {
    @Test func oneShotUnsafeFormsReturnExactValuesAndCleanUp() async throws {
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func unsafeContinuationProbe() async throws -> String {
            let ordinary: Int = await withUnsafeContinuation(
                isolation: MainActor.shared
            ) { continuation in
                continuation.resume(returning: 33)
            }
            let throwing: Int = try await withUnsafeThrowingContinuation(
                isolation: MainActor.shared
            ) { continuation in
                continuation.resume(returning: 44)
            }
            return "\\(ordinary)|\\(throwing)"
        }
        try await unsafeContinuationProbe()
        """)

        #expect(value.stringValue == "33|44")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func delayedResultResumeSharesTransitionsAndCleansUp()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "unsafe-continuation-result-resume.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait unsafeContinuationResultResumeProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "value:29|error:failed|void:resumed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 3)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 3)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }
}
