import Testing
@testable import SwiftInterpreter

@Suite("Interpreter session ownership")
struct InterpreterSessionOwnershipTests {
    @Test func sessionBindsProgramHeapRuntimePolicyAndLiveRuntimeID()
    async throws {
        let interpreter = Interpreter()
        weak let observedInterpreter = interpreter
        interpreter.globals.define(
            "currentRuntimeSession",
            .hostFunction(HostFunction(
                name: "currentRuntimeSession",
                invoke: { _, _ in
                    .native(observedInterpreter?.evaluationTaskContext
                        .runtimeSessionID?.description ?? "none")
                })))
        let program = try ParsedProgram(source: "currentRuntimeSession()")
        let session = interpreter.makeSession(
            program: program,
            lazyTopLevelGlobals: false,
            completionPolicy: .drainOwnedTasks)

        #expect(session.program.source == program.source)
        #expect(session.heap === interpreter.runtimeHeap)
        #expect(session.concurrencyRuntime === interpreter.concurrencyRuntime)
        #expect(session.runtimeEntry.kind == .program)
        #expect(session.runtimeEntry.heap === interpreter.runtimeHeap)
        #expect(session.runtimeEntry.interpreter === interpreter)
        #expect(session.runtimeEntry.id == session.id)
        #expect(session.runtimeEntry.callableMetadataIndex?.summary
            == program.callableMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.propertyMetadataIndex
            .summary == program.propertyMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.enumCaseMetadataIndex
            .summary == program.enumCaseMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.extensionMetadataIndex
            .summary == program.extensionMetadataIndex.summary)
        if case .drainOwnedTasks = session.completionPolicy {
            // Expected policy is bound into the session.
        } else {
            Issue.record("session lost its completion policy")
        }
        #expect(session.state == .ready)

        let value = try await interpreter.runAsync(session: session)

        #expect(value.stringValue == session.id.description)
        #expect(session.state == .finished)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func sessionsHaveUniqueRuntimeIdentityAndAreSingleUse() async throws {
        let interpreter = Interpreter()
        let program = try ParsedProgram(source: "42")
        let first = interpreter.makeSession(program: program)
        let second = interpreter.makeSession(program: program)

        #expect(first.id != second.id)
        #expect(try await interpreter.runAsync(session: first).intValue == 42)

        do {
            _ = try await interpreter.runAsync(session: first)
            Issue.record("expected a completed session to reject reuse")
        } catch let error as RuntimeError {
            #expect(error.message.contains("already started"))
        }
    }

    @Test func sessionRejectsExecutionByAnotherInterpreter() async throws {
        let owner = Interpreter()
        let other = Interpreter()
        let session = owner.makeSession(
            program: try ParsedProgram(source: "42"))

        do {
            _ = try await other.runAsync(session: session)
            Issue.record("expected a foreign interpreter to be rejected")
        } catch let error as RuntimeError {
            #expect(error.message.contains("different interpreter"))
        }
        #expect(session.state == .ready)
        #expect(owner.concurrencyRuntime.activeRecordCount == 0)
        #expect(other.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func sessionKeepsItsHeapAndRuntimeAliveWithoutRetainingFacade()
    throws {
        weak var releasedFacade: Interpreter?
        weak var releasedHeap: RuntimeHeap?
        weak var releasedRuntime: CooperativeConcurrencyRuntime?
        var session: InterpreterSession?

        do {
            var interpreter: Interpreter? = Interpreter()
            releasedFacade = interpreter
            session = interpreter?.makeSession(
                program: try ParsedProgram(source: "42"))
            releasedHeap = interpreter?.runtimeHeap
            releasedRuntime = interpreter?.concurrencyRuntime
            interpreter = nil
        }

        #expect(releasedFacade == nil)
        #expect(releasedHeap != nil)
        #expect(releasedRuntime != nil)
        #expect(session != nil)
        session = nil
        #expect(releasedHeap == nil)
        #expect(releasedRuntime == nil)
    }
}
