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
        let program = try ParsedProgram(source: """
        final class Lifetime { deinit {} }
        currentRuntimeSession()
        """)
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
        #expect(session.programState === session.runtimeEntry.programState)
        #expect(session.programState.programPlan === session.programPlan)
        #expect(session.runtimeEntry.callableMetadataIndex?.summary
            == program.callableMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.propertyMetadataIndex
            .summary == program.propertyMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.enumCaseMetadataIndex
            .summary == program.enumCaseMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.extensionMetadataIndex
            .summary == program.extensionMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.typeAliasMetadataIndex
            .summary == program.typeAliasMetadataIndex.summary)
        #expect(session.runtimeEntry.programMetadata?.deinitializerMetadataIndex
            .summary == program.deinitializerMetadataIndex.summary)
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

    @Test func sessionsOwnDistinctMutableDeclarationState() async throws {
        let interpreter = Interpreter()
        let first = interpreter.makeSession(
            program: try ParsedProgram(source: """
            struct FirstMarker {}
            FirstMarker()
            """))
        let second = interpreter.makeSession(
            program: try ParsedProgram(source: """
            struct SecondMarker {}
            SecondMarker()
            """))

        #expect(first.programState !== second.programState)
        #expect(first.programState.programPlan === first.programPlan)
        #expect(second.programState.programPlan === second.programPlan)
        #expect(first.runtimeEntry.programState === first.programState)
        #expect(second.runtimeEntry.programState === second.programState)

        _ = try await interpreter.runAsync(session: first)
        #expect(first.programState.structSymbols.contains {
            $0.name == "FirstMarker"
        })
        #expect(!first.programState.structSymbols.contains {
            $0.name == "SecondMarker"
        })

        _ = try await interpreter.runAsync(session: second)
        #expect(second.programState.structSymbols.contains {
            $0.name == "SecondMarker"
        })
        #expect(!second.programState.structSymbols.contains {
            $0.name == "FirstMarker"
        })
    }

    @Test func retainedClosureActivatesItsOriginatingProgramState() async throws {
        let interpreter = Interpreter()
        _ = try await interpreter.runAsync(source: """
        actor SessionCounter {
            var value = 0

            func next() async -> Int {
                await Task.yield()
                value += 1
                return value
            }
        }

        func nextFromOrigin() async -> Int {
            let counter = SessionCounter()
            return await counter.next()
        }

        0
        """)

        let value = try await interpreter.runAsync(source: """
        await nextFromOrigin()
        """)

        #expect(value.intValue == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test func retainedClosureUsesOriginatingStateForSynchronousDispatch()
    throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        func selected(_ value: String) -> String { "string" }
        func selected(_ value: Int) -> String { "int" }

        func selectFromOrigin() -> String {
            selected("origin")
        }

        0
        """)

        let value = try interpreter.run(source: """
        selectFromOrigin()
        """)

        #expect(value.stringValue == "string")
        #expect(interpreter.evaluationTaskContext.programStateFrames.isEmpty)
    }

    @Test func newerRunResolvesRetainedHostExtensionFromItsOriginState()
    throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        extension String {
            func retainedSelection() -> String {
                selected(self)
            }
        }

        func selected(_ value: String) -> String { "string" }
        func selected(_ value: Int) -> String { "int" }
        0
        """)

        let value = try interpreter.run(source: """
        "origin".retainedSelection()
        """)

        #expect(value.stringValue == "string")
        #expect(interpreter.evaluationTaskContext.programStateFrames.isEmpty)
    }

    @Test func newerHostExtensionUsesOneWayProgramStateOverlay() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        extension String {
            func originMember() -> String { "origin" }
        }
        0
        """)
        let originState = try #require(interpreter.compatibilityProgramState)
        let originSymbol = try #require(
            originState.hostExtensionSymbols["String"])

        let value = try interpreter.run(source: """
        extension String {
            func newerMember() -> String { "newer" }
        }
        "x".originMember() + ":" + "x".newerMember()
        """)

        #expect(value.stringValue == "origin:newer")
        #expect(originSymbol.methods["newerMember"] == nil)
    }

    @Test func visibleHostExtensionSnapshotCachesUntilLineageChanges() {
        let parent = RuntimeProgramState()
        let stringSymbol = StructSymbol(
            name: "String", conformsToView: false)
        parent.hostExtensionSymbols["String"] = stringSymbol
        let child = RuntimeProgramState(hostExtensionParent: parent)

        let initial = child.visibleHostExtensionSymbols
        let repeated = child.visibleHostExtensionSymbols

        #expect(initial["String"] === stringSymbol)
        #expect(repeated["String"] === stringSymbol)
        #expect(child.visibleHostExtensionMaterializationCount == 1)

        let integerSymbol = StructSymbol(
            name: "Int", conformsToView: false)
        parent.hostExtensionSymbols["Int"] = integerSymbol

        #expect(child.visibleHostExtensionSymbols["Int"] === integerSymbol)
        #expect(child.visibleHostExtensionMaterializationCount == 2)
    }

    @Test func expressionOnlyRunsDoNotRetainEmptyProgramStateLineage() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: "0")
        weak var releasedState = interpreter.compatibilityProgramState

        _ = try interpreter.run(source: "1")

        #expect(releasedState == nil)
        #expect(interpreter.compatibilityProgramState?.hostExtensionParent == nil)
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
        weak var releasedProgramState: RuntimeProgramState?
        var session: InterpreterSession?

        do {
            var interpreter: Interpreter? = Interpreter()
            releasedFacade = interpreter
            session = interpreter?.makeSession(
                program: try ParsedProgram(source: "42"))
            releasedHeap = interpreter?.runtimeHeap
            releasedRuntime = interpreter?.concurrencyRuntime
            releasedProgramState = session?.programState
            interpreter = nil
        }

        #expect(releasedFacade == nil)
        #expect(releasedHeap != nil)
        #expect(releasedRuntime != nil)
        #expect(releasedProgramState != nil)
        #expect(session != nil)
        session = nil
        #expect(releasedHeap == nil)
        #expect(releasedRuntime == nil)
        #expect(releasedProgramState == nil)
    }
}
