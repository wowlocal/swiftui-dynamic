import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Task cancellation runtime")
struct TaskCancellationRuntimeTests {
    @Test
    func cancellingAValueWaiterDoesNotCancelItsTarget() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-value-waiter-cancellation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskValueWaiterCancellationProbe()\n"
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
            Issue.record("expected waiter-cancellation recorder")
            return
        }

        func handle(_ name: String) throws -> RuntimeTaskHandle {
            let value = try #require(
                recorder.box(for: name)?.value.unwrappedOptionalOrSelf)
            return try #require(value.hostPayload as? RuntimeTaskHandle)
        }

        let target = try handle("target")
        let waiter = try handle("waiter")
        #expect(recorder.box(for: "result")?.value.stringValue
            == "target-active,waiter-cancelled")
        #expect(recorder.box(for: "handleWasCancelled")?.value.boolValue == true)
        #expect(target.state == .succeeded)
        #expect(target.result?.stringValue == "target-active")
        #expect(!target.isCancelled)
        #expect(waiter.state == .succeeded)
        #expect(waiter.result?.stringValue
            == "target-active,waiter-cancelled")
        #expect(waiter.isCancelled)
        #expect(waiter.cancellation.sources == [.taskHandle])
        #expect(waiter.cancellation.isObserved)
        let requestSequence = try #require(
            waiter.cancellation.requestSequence)
        let observationSequence = try #require(
            waiter.cancellation.observationSequence)
        #expect(requestSequence < observationSequence)
        #expect(target.waiterCount == 0)
        #expect(waiter.waitingOnTaskIDs.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
