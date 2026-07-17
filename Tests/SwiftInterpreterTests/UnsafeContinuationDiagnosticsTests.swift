import Testing
@testable import SwiftInterpreter

@Suite("Unsafe continuation diagnostics")
struct UnsafeContinuationDiagnosticsTests {
    @Test func unsafeContinuationFailsClosedBeforeOwnership() async throws {
        let interpreter = Interpreter()

        do {
            _ = try await interpreter.runAsync(source: """
                @MainActor var unsafeContinuationBodyRan = false
                let _: Int = await withUnsafeContinuation(
                    isolation: MainActor.shared
                ) { continuation in
                    unsafeContinuationBodyRan = true
                    continuation.resume(returning: 33)
                }
                """)
            Issue.record("unsafe continuation was silently executed")
        } catch let error as RuntimeError {
            #expect(error.message
                == "withUnsafeContinuation: unsafe continuation ownership "
                    + "is unsupported; use a checked continuation")
        }

        #expect(interpreter.globals.lookup(
            "unsafeContinuationBodyRan")?.boolValue == false)
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
