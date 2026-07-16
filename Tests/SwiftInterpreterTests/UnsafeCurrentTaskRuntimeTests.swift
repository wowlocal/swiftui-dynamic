import Testing
@testable import SwiftInterpreter

@Suite("Unsafe current task runtime")
struct UnsafeCurrentTaskRuntimeTests {
    @Test
    func synchronousCallOutsideRuntimeTaskReceivesNil() throws {
        let interpreter = Interpreter()

        let value = try interpreter.run(source: """
        withUnsafeCurrentTask { current in
            current == nil
        }
        """)

        #expect(value.boolValue == true)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func asyncRootReceivesCapabilityWithoutRetainingTaskRecord() async throws {
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: """
        await withUnsafeCurrentTask { current in
            await Task.yield()
            return current != nil
        }
        """)

        #expect(value.boolValue == true)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func hostCallbackUsesItsCanonicalLogicalTask() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        func currentTaskFromCallback() -> Bool {
            withUnsafeCurrentTask { current in
                current != nil
            }
        }
        """)
        guard case .closure(let closure)? =
                interpreter.globals.lookup("currentTaskFromCallback") else {
            Issue.record("callback declaration was not collected")
            return
        }

        let value = try interpreter.callHostCallback(closure, arguments: [])

        #expect(value.boolValue == true)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func capabilityFailsClosedAfterBodyLeaseEnds() async throws {
        for member in ["isCancelled", "hashValue"] {
            do {
                _ = try await Interpreter().runAsync(source: """
                let escaped = withUnsafeCurrentTask { current in current }
                escaped!.\(member)
                """)
                Issue.record(
                    "escaped current-task \(member) unexpectedly remained valid")
            } catch let error as RuntimeError {
                #expect(error.message.contains(
                    "escaped the dynamic extent of its operation"))
            }
        }
    }

    @Test
    func readingCancellationRecordsCooperativeObservation() throws {
        let runtime = CooperativeConcurrencyRuntime()
        let record = runtime.createTask(
            sessionID: runtime.createSession(),
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .cooperativeDefault,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        let capability = RuntimeUnsafeCurrentTask(
            runtime: runtime,
            taskID: record.id,
            lease: RuntimeUnsafeCurrentTaskLease())
        runtime.requestCancellation(record, source: .taskHandle)

        #expect(!record.cancellation.isObserved)
        #expect(try capability.isCancelled())
        #expect(record.cancellation.isObserved)
        let requestSequence = try #require(
            record.cancellation.requestSequence)
        let observationSequence = try #require(
            record.cancellation.observationSequence)
        #expect(requestSequence < observationSequence)
    }

    @Test(arguments: ["escalatePriority", "unownedTaskExecutor"])
    func generatedButUnsupportedMembersFailClosed(_ member: String) async throws {
        let expression: String
        if member == "escalatePriority" {
            expression = "current!.escalatePriority(to: .high)"
        } else {
            expression = "current!.unownedTaskExecutor"
        }
        do {
            _ = try await Interpreter().runAsync(source: """
            withUnsafeCurrentTask { current in
                \(expression)
            }
            """)
            Issue.record("UnsafeCurrentTask.\(member) unexpectedly ran")
        } catch let error as RuntimeError {
            #expect(error.message.contains(
                "UnsafeCurrentTask.\(member) is declared"))
            #expect(error.message.contains("not supported yet"))
        }
    }

    @Test
    func everyGeneratedUnroutedMemberHasExplicitDiagnostic() throws {
        let interpreter = Interpreter()
        let capability = RuntimeUnsafeCurrentTask(
            runtime: interpreter.concurrencyRuntime,
            taskID: RuntimeTaskID(rawValue: 999),
            lease: RuntimeUnsafeCurrentTaskLease())

        for member in ["hash", "escalatePriority", "unownedTaskExecutor"] {
            do {
                _ = try interpreter.nativeMember(member, on: capability)
                Issue.record("UnsafeCurrentTask.\(member) unexpectedly resolved")
            } catch let error as RuntimeError {
                #expect(error.message.contains(
                    "UnsafeCurrentTask.\(member) is declared"))
                #expect(error.message.contains("not supported yet"))
            }
        }
    }
}
