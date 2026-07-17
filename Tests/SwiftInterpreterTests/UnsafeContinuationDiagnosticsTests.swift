import Testing
@testable import SwiftInterpreter

@Suite("Unsafe continuation diagnostics")
struct UnsafeContinuationDiagnosticsTests {
    @Test func unsafeContinuationFailsClosedBeforeOwnership() async throws {
        try await Self.assertFailsClosed(
            functionName: "withUnsafeContinuation",
            bodyFlag: "unsafeContinuationBodyRan",
            source: """
            @MainActor var unsafeContinuationBodyRan = false
            let _: Int = await withUnsafeContinuation(
                isolation: MainActor.shared
            ) { continuation in
                unsafeContinuationBodyRan = true
                continuation.resume(returning: 33)
            }
            """)
    }

    @Test func unsafeThrowingContinuationFailsClosedBeforeOwnership()
            async throws {
        try await Self.assertFailsClosed(
            functionName: "withUnsafeThrowingContinuation",
            bodyFlag: "unsafeThrowingContinuationBodyRan",
            source: """
            @MainActor var unsafeThrowingContinuationBodyRan = false
            let _: Int = try await withUnsafeThrowingContinuation(
                isolation: MainActor.shared
            ) { continuation in
                unsafeThrowingContinuationBodyRan = true
                continuation.resume(returning: 44)
            }
            """)
    }

    private static func assertFailsClosed(
        functionName: String,
        bodyFlag: String,
        source: String
    ) async throws {
        let interpreter = Interpreter()

        do {
            _ = try await interpreter.runAsync(source: source)
            Issue.record("\(functionName) was silently executed")
        } catch let error as RuntimeError {
            #expect(error.message
                == "\(functionName): unsafe continuation ownership "
                    + "is unsupported; use a checked continuation")
        }

        #expect(interpreter.globals.lookup(
            bodyFlag)?.boolValue == false)
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }
}
