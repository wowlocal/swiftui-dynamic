import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Task completion runtime")
struct TaskCompletionRuntimeTests {
    @Test
    func completedHandlesRetainTypedOutcomesAfterRuntimeRelease() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-completed-handle-reads.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait startTaskCompletedHandleReadProbe()\n"
        let interpreter = Interpreter()
        interpreter.globals.define("parityYield", .hostFunction(HostFunction(
            name: "parityYield",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let value = try await interpreter.runAsync(source: source)
        guard case .instance(let recorder) = value else {
            Issue.record("expected completed-handle recorder")
            return
        }

        func handle(_ name: String) throws -> RuntimeTaskHandle {
            let value = try #require(
                recorder.box(for: name)?.value.unwrappedOptionalOrSelf)
            return try #require(value.hostPayload as? RuntimeTaskHandle)
        }

        let success = try handle("success")
        let failure = try handle("failure")
        #expect(recorder.box(for: "output")?.value.stringValue
            == "value,value,success:value,failure,failure,get-caught")

        #expect(success.state == .succeeded)
        #expect(success.isCompleted)
        #expect(!success.isCancelled)
        guard case .success(let successValue, let successType)? =
                success.outcome else {
            Issue.record("expected retained success outcome")
            return
        }
        #expect(successValue.stringValue == "value")
        #expect(successType == "String")

        #expect(failure.state == .failed)
        #expect(failure.isCompleted)
        #expect(!failure.isCancelled)
        guard case .failure(let failureValue, let failureType)? =
                failure.outcome else {
            Issue.record("expected retained failure outcome")
            return
        }
        #expect(failureType == "TaskCompletedHandleReadError")
        guard case .enumCase(let errorCase) = failureValue else {
            Issue.record("expected retained interpreted error value")
            return
        }
        #expect(errorCase.symbol.name == "TaskCompletedHandleReadError")
        #expect(errorCase.name == "failed")

        #expect(success.waiterCount == 0)
        #expect(failure.waiterCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
