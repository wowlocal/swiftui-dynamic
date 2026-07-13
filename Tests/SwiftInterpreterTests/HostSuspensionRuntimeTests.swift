import Foundation
import Testing
@testable import SwiftInterpreter

@MainActor
private final class HostGatewaySuspensionState {
    var events: [String] = []
    var started = false
    var gateOpen = false
    var rootRecord: RuntimeTaskRecord?
    var observedState: RuntimeTaskState?
    var observedSuspension: RuntimeSuspension?
    var observedHistory: [RuntimeSuspension] = []
    var observedOperationID: HostOperationID?
    var observedOperationTaskID: RuntimeTaskID?
    var observedHostOperationCount = 0
}

@Suite("Host suspension runtime")
struct HostSuspensionRuntimeTests {
    @Test
    func asyncGatewayRecordsFirstClassHostSuspension() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("host-gateway-suspension.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait hostGatewaySuspensionProbe()\n"
        let interpreter = Interpreter()
        let state = HostGatewaySuspensionState()

        interpreter.globals.define(
            "parityRecordHostGatewayEvent",
            .hostFunction(HostFunction(
                name: "parityRecordHostGatewayEvent"
            ) { arguments, _ in
                state.events.append(
                    arguments.positional(0)?.stringValue ?? "?")
                return .void
            }))
        interpreter.globals.define(
            "parityHostGatewayValue",
            .hostFunction(HostFunction(
                name: "parityHostGatewayValue",
                asyncInvoke: { arguments, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let taskID = bound.evaluationContext.runtimeTaskID,
                          let record = interpreter.concurrencyRuntime
                            .records[taskID] else {
                        throw RuntimeError(message:
                            "host suspension requires a runtime root task")
                    }
                    state.rootRecord = record
                    state.events.append("host-enter")
                    state.started = true
                    while !state.gateOpen { await Task.yield() }
                    state.events.append("host-exit")
                    return arguments.positional(0) ?? .nilValue
                })))
        interpreter.globals.define(
            "parityAwaitHostGatewayStarted",
            .hostFunction(HostFunction(
                name: "parityAwaitHostGatewayStarted",
                asyncInvoke: { _, _ in
                    while !state.started { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "parityOpenHostGateway",
            .hostFunction(HostFunction(
                name: "parityOpenHostGateway"
            ) { _, _ in
                guard let record = state.rootRecord else {
                    throw RuntimeError(message:
                        "host gate opened before operation entry")
                }
                state.observedState = record.state
                state.observedSuspension = record.suspension
                state.observedHistory = record.suspensionHistory
                if case .awaitingHost(let operationID) = record.suspension {
                    state.observedOperationID = operationID
                    state.observedOperationTaskID = interpreter
                        .concurrencyRuntime.hostOperations[operationID]
                }
                state.observedHostOperationCount = interpreter
                    .concurrencyRuntime.activeHostOperationCount
                state.gateOpen = true
                return .void
            }))
        interpreter.globals.define(
            "parityHostGatewayEvents",
            .hostFunction(HostFunction(
                name: "parityHostGatewayEvents"
            ) { _, _ in
                .native(state.events.joined(separator: ","))
            }))

        let result = try await interpreter.runAsync(source: source)
        let root = try #require(state.rootRecord)
        #expect(result.stringValue
            == "before,host-enter,controller,host-exit,value")
        let operationID = try #require(state.observedOperationID)
        #expect(state.observedState == .waiting)
        #expect(state.observedSuspension == .awaitingHost(operationID))
        #expect(state.observedHistory.last == .awaitingHost(operationID))
        #expect(state.observedOperationTaskID == root.id)
        #expect(state.observedHostOperationCount == 1)
        #expect(root.state == .succeeded)
        #expect(root.suspension == nil)
        #expect(root.suspensionHistory == [.awaitingHost(operationID)])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
    }
}
