import Foundation
import Testing
@testable import SwiftInterpreter

private struct NativeAsyncCounter {
    var value: Int

    mutating func bump() async {
        await Task.yield()
        value += 1
    }
}

private struct NativeNestedAsyncCounter {
    var value: Int

    mutating func update() async {
        await bump()
    }

    private mutating func bump() async {
        await Task.yield()
        value += 1
    }
}

private enum DetachedRuntimeProbeLocal {
    @TaskLocal static var value = "default"
}

@MainActor
private final class YieldProgressGate {
    var reached = false
    var released = false
}

@MainActor
private final class HostSessionAbortProbeState {
    var started = false
    var sourceCatchCount = 0
    var rootRecord: RuntimeTaskRecord?
}

@MainActor
private final class HostReentrySuspensionState {
    var rootRecord: RuntimeTaskRecord?
    var outerOperationID: HostOperationID?
    var callbackState: RuntimeTaskState?
    var callbackSuspension: RuntimeSuspension?
    var callbackHostOperationCount = 0
    var callbackOuterTaskID: RuntimeTaskID?
    var nestedOperationID: HostOperationID?
    var nestedState: RuntimeTaskState?
    var nestedHostOperationCount = 0
    var nestedOuterTaskID: RuntimeTaskID?
    var nestedOperationTaskID: RuntimeTaskID?
}

@Suite("Async execution")
struct AsyncExecutionTests {
    private enum ProbeError: Error, CustomStringConvertible {
        case failed

        var description: String { "probe failed" }
    }

    private func stringArray(
        named property: String, in value: RuntimeValue
    ) throws -> [String] {
        guard case .instance(let instance) = value else {
            Issue.record("expected an interpreted instance")
            return []
        }
        return try #require(instance.box(for: property)?.value.arrayValue).compactMap(\.stringValue)
    }

    @Test func asyncMutatingStructMethodCopiesOutLikeNativeSwift() async throws {
        let nativeOriginal = NativeAsyncCounter(value: 1)
        var nativeCopy = nativeOriginal
        await nativeCopy.bump()
        let native = "\(nativeOriginal.value) \(nativeCopy.value)"

        let interpreter = Interpreter()
        interpreter.globals.define("yielding", .hostFunction(HostFunction(
            name: "yielding",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))
        let interpreted = try await interpreter.runAsync(source: #"""
        struct Counter {
            var value: Int
            mutating func bump() async {
                value = await yielding(value) + 1
            }
        }
        let original = Counter(value: 1)
        var copy = original
        await copy.bump()
        "\(original.value) \(copy.value)"
        """#)

        #expect(interpreted.stringValue == native)
    }

    @Test func nestedAsyncMutatingMethodCopiesOutLikeNativeSwift() async throws {
        var nativeCounter = NativeNestedAsyncCounter(value: 4)
        await nativeCounter.update()

        let interpreter = Interpreter()
        interpreter.globals.define("yielding", .hostFunction(HostFunction(
            name: "yielding",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))
        let interpreted = try await interpreter.runAsync(source: #"""
        struct Counter {
            var value: Int

            mutating func update() async {
                await bump()
            }

            private mutating func bump() async {
                value = await yielding(value) + 1
            }
        }

        var counter = Counter(value: 4)
        await counter.update()
        counter.value
        """#)

        #expect(interpreted.intValue == nativeCounter.value)
    }

    @Test func runAsyncMatchesNativeTaskOrdering() async throws {
        var nativeEvents: [String] = []
        let nativeTask = Task { @MainActor in
            nativeEvents.append("task")
        }
        nativeEvents.append("sync")
        await nativeTask.value

        let interpreter = Interpreter()
        let state = try await interpreter.runAsync(source: """
        class State { var events = [String]() }
        let state = State()
        let handle = Task { state.events.append("task") }
        state.events.append("sync")
        state
        """)

        #expect(try stringArray(named: "events", in: state) == nativeEvents)
        guard case .host(let any)? = interpreter.globals.lookup("handle"),
              let handle = any as? RuntimeTaskHandle else {
            Issue.record("Task should return a runtime task handle")
            return
        }
        #expect(handle.state == .succeeded)
        #expect(handle.isCompleted)
    }

    @Test func cancellationBeforeStartMatchesNativeTask() async throws {
        var nativeRan = false
        var nativeWasCancelled = false
        let nativeTask = Task { @MainActor in
            nativeRan = true
            nativeWasCancelled = Task.isCancelled
            return "body-value"
        }
        nativeTask.cancel()
        let nativeValue = await nativeTask.value

        let interpreter = Interpreter()
        let state = try await interpreter.runAsync(source: """
        class State {
            var ran = false
            var wasCancelled = false
        }
        let state = State()
        let handle = Task {
            state.ran = true
            state.wasCancelled = Task.isCancelled
            return "body-value"
        }
        handle.cancel()
        let value = await handle.value
        state
        """)

        guard case .instance(let instance) = state else {
            Issue.record("expected an interpreted State")
            return
        }
        #expect(instance.box(for: "ran")?.value.boolValue == nativeRan)
        #expect(instance.box(for: "wasCancelled")?.value.boolValue
            == nativeWasCancelled)
        guard case .host(let any)? = interpreter.globals.lookup("handle"),
              let handle = any as? RuntimeTaskHandle else {
            Issue.record("Task should return a runtime task handle")
            return
        }
        #expect(handle.state == .succeeded)
        #expect(handle.result?.stringValue == nativeValue)
        #expect(handle.isCancelled == nativeTask.isCancelled)
        #expect(handle.isCompleted)
    }

    @Test func runAsyncWaitsForDescendantTasks() async throws {
        let interpreter = Interpreter()
        let state = try await interpreter.runAsync(source: """
        class State { var events = [String]() }
        let state = State()
        Task {
            state.events.append("parent")
            Task { state.events.append("child") }
        }
        state.events.append("sync")
        state
        """)

        #expect(try stringArray(named: "events", in: state) == ["sync", "parent", "child"])
    }

    @Test func topLevelSessionPolicyReturnsBeforeOwnedTaskCompletes() async throws {
        let interpreter = Interpreter()
        var taskStarted = false
        var gateOpen = false
        var runReturned = false
        interpreter.globals.define("waitForSessionGate", .hostFunction(HostFunction(
            name: "waitForSessionGate",
            asyncInvoke: { _, _ in
                taskStarted = true
                while !gateOpen { await Task.yield() }
                return .void
            }
        )))

        let evaluation = Task { @MainActor in
            let value = try await interpreter.runAsync(
                source: """
                class State { var events = [String]() }
                let state = State()
                Task {
                    await waitForSessionGate()
                    state.events.append("task")
                }
                state.events.append("top")
                state
                """,
                completionPolicy: .topLevel)
            runReturned = true
            return value
        }

        while !taskStarted { await Task.yield() }
        #expect(runReturned)
        gateOpen = true
        let state = try await evaluation.value
        while interpreter.concurrencyRuntime.activeRecordCount != 0 {
            await Task.yield()
        }
        #expect(try stringArray(named: "events", in: state) == ["top", "task"])
    }

    @Test func drainPolicyDoesNotWaitForAnotherSessionTasks() async throws {
        let interpreter = Interpreter()
        var firstTaskStarted = false
        var firstGateOpen = false
        interpreter.globals.define("waitForFirstSessionGate", .hostFunction(HostFunction(
            name: "waitForFirstSessionGate",
            asyncInvoke: { _, _ in
                firstTaskStarted = true
                while !firstGateOpen { await Task.yield() }
                return .void
            }
        )))

        let firstState = try await interpreter.runAsync(
            source: """
            class FirstSessionState { var events = [String]() }
            let firstSessionState = FirstSessionState()
            Task {
                await waitForFirstSessionGate()
                firstSessionState.events.append("first-task")
            }
            firstSessionState.events.append("first-top")
            firstSessionState
            """,
            completionPolicy: .topLevel)
        while !firstTaskStarted { await Task.yield() }

        let secondResult = try await interpreter.runAsync(
            source: """
            let secondHandle = Task { "second-task" }
            await secondHandle.value
            """,
            completionPolicy: .drainOwnedTasks)
        #expect(secondResult.stringValue == "second-task")
        #expect(try stringArray(named: "events", in: firstState) == ["first-top"])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 1)

        firstGateOpen = true
        while interpreter.concurrencyRuntime.activeRecordCount != 0 {
            await Task.yield()
        }
        #expect(try stringArray(named: "events", in: firstState)
            == ["first-top", "first-task"])
    }

    @Test func cancelRemainingPolicyCancelsRunningOwnedTasksAndCleansUp() async throws {
        let interpreter = Interpreter()
        var waitStarted = false
        var sourceCatchCount = 0
        interpreter.globals.define("waitForCancellationPolicy", .hostFunction(HostFunction(
            name: "waitForCancellationPolicy",
            asyncInvoke: { _, _ in
                waitStarted = true
                try await Task.sleep(for: .seconds(30))
                return .void
            }
        )))
        interpreter.globals.define("awaitCancellationPolicyStarted", .hostFunction(HostFunction(
            name: "awaitCancellationPolicyStarted",
            asyncInvoke: { _, _ in
                while !waitStarted { await Task.yield() }
                return .void
            }
        )))
        interpreter.globals.define(
            "recordCancellationPolicySourceCatch",
            .hostFunction(HostFunction(
                name: "recordCancellationPolicySourceCatch",
                invoke: { _, _ in
                    sourceCatchCount += 1
                    return .void
                })))

        _ = try await interpreter.runAsync(
            source: """
            let cancellationPolicyHandle = Task {
                do {
                    try await waitForCancellationPolicy()
                    return "unexpected"
                } catch is CancellationError {
                    recordCancellationPolicySourceCatch()
                    return "caught"
                }
            }
            await awaitCancellationPolicyStarted()
            "top-finished"
            """,
            completionPolicy: .cancelRemainingTasks)

        guard case .host(let payload)? =
                interpreter.globals.lookup("cancellationPolicyHandle"),
              let handle = payload as? RuntimeTaskHandle else {
            Issue.record("expected cancellation-policy task handle")
            return
        }
        #expect(waitStarted)
        #expect(sourceCatchCount == 0)
        #expect(handle.state == .cancelled)
        #expect(handle.isCancelled)
        #expect(handle.cancellation.sources == [.sessionPolicy])
        #expect(handle.cancellation.isObserved)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func synchronousRunRetainsInlineTaskCompatibility() throws {
        let interpreter = Interpreter()
        let state = try interpreter.run(source: """
        class State { var events = [String]() }
        let state = State()
        Task { state.events.append("task") }
        state.events.append("sync")
        state
        """)

        #expect(try stringArray(named: "events", in: state) == ["task", "sync"])
    }

    @Test func synchronousRunBoundsRecursivelyCreatedTasks() throws {
        let interpreter = Interpreter()
        let state = try interpreter.run(source: """
        class State { var events = [String]() }
        let state = State()
        Task {
            state.events.append("parent")
            Task { state.events.append("child") }
        }
        state
        """)

        #expect(try stringArray(named: "events", in: state) == ["parent"])
    }

    @Test func completedSessionsReleaseSchedulerTracking() async throws {
        let interpreter = Interpreter()

        _ = try await interpreter.runAsync(source: "Task { _ = 1 }")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        _ = try await interpreter.runAsync(source: "Task { _ = 2 }")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func runtimeAssignsDistinctTaskIDsAndOneRootParent() async throws {
        let interpreter = Interpreter()
        _ = try await interpreter.runAsync(source: """
        let first = Task { "first" }
        let second = Task { "second" }
        """)

        guard case .host(let firstPayload)? = interpreter.globals.lookup("first"),
              let first = firstPayload as? RuntimeTaskHandle,
              case .host(let secondPayload)? = interpreter.globals.lookup("second"),
              let second = secondPayload as? RuntimeTaskHandle else {
            Issue.record("expected two runtime task handles")
            return
        }
        #expect(first.id != second.id)
        #expect(first.kind == .unstructured)
        #expect(second.kind == .unstructured)
        #expect(first.parent != nil)
        #expect(first.parent == second.parent)
        #expect(first.sessionID == second.sessionID)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func unstructuredSpawnEdgeDoesNotBecomeStructuredOwnership() async throws {
        let interpreter = Interpreter()
        var registeredChild: RuntimeTaskHandle?
        var parentGateOpen = false
        var childGateOpen = false
        interpreter.globals.define(
            "registerSpawnGraphChild",
            .hostFunction(HostFunction(
                name: "registerSpawnGraphChild"
            ) { arguments, _ in
                registeredChild = arguments.positional(0)?.hostPayload
                    as? RuntimeTaskHandle
                return .void
            }))
        interpreter.globals.define(
            "awaitSpawnGraphRegistration",
            .hostFunction(HostFunction(
                name: "awaitSpawnGraphRegistration",
                asyncInvoke: { _, _ in
                    while registeredChild == nil { await Task.yield() }
                    return .void
                }
            )))
        interpreter.globals.define(
            "waitForSpawnGraphParentGate",
            .hostFunction(HostFunction(
                name: "waitForSpawnGraphParentGate",
                asyncInvoke: { _, _ in
                    while !parentGateOpen { await Task.yield() }
                    return .void
                }
            )))
        interpreter.globals.define(
            "waitForSpawnGraphChildGate",
            .hostFunction(HostFunction(
                name: "waitForSpawnGraphChildGate",
                asyncInvoke: { _, _ in
                    while !childGateOpen { await Task.yield() }
                    return .void
                }
            )))
        interpreter.globals.define(
            "openSpawnGraphGates",
            .hostFunction(HostFunction(name: "openSpawnGraphGates") { _, _ in
                parentGateOpen = true
                childGateOpen = true
                return .void
            }))

        _ = try await interpreter.runAsync(source: """
        let spawnGraphParent = Task {
            let child = Task {
                await waitForSpawnGraphChildGate()
                return "child"
            }
            registerSpawnGraphChild(child)
            await waitForSpawnGraphParentGate()
            return "parent"
        }
        await awaitSpawnGraphRegistration()
        spawnGraphParent.cancel()
        openSpawnGraphGates()
        await spawnGraphParent.value
        """)

        guard case .host(let parentPayload)? =
                interpreter.globals.lookup("spawnGraphParent"),
              let parent = parentPayload as? RuntimeTaskHandle,
              let child = registeredChild else {
            Issue.record("expected parent and child runtime task handles")
            return
        }
        #expect(child.parent == parent.id)
        #expect(parent.spawnedTaskIDs == Set([child.id]))
        #expect(parent.structuredChildIDs.isEmpty)
        #expect(parent.cancellation.sources.contains(.taskHandle))
        #expect(!child.isCancelled)
        #expect(child.state == .succeeded)
        #expect(child.result?.stringValue == "child")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func caughtCancellationKeepsRequestAndSuccessfulOutcome() async throws {
        let interpreter = Interpreter()
        var waitStarted = false
        interpreter.globals.define("waitForCaughtCancellation", .hostFunction(HostFunction(
            name: "waitForCaughtCancellation",
            asyncInvoke: { _, _ in
                waitStarted = true
                try await Task.sleep(for: .seconds(30))
                return .void
            }
        )))
        interpreter.globals.define("awaitCaughtCancellationStarted", .hostFunction(HostFunction(
            name: "awaitCaughtCancellationStarted",
            asyncInvoke: { _, _ in
                while !waitStarted { await Task.yield() }
                return .void
            }
        )))

        _ = try await interpreter.runAsync(source: """
        func recoverFromCancellation() async -> String {
            do {
                await waitForCaughtCancellation()
                return "not-cancelled"
            } catch {
                return "caught"
            }
        }
        let caughtCancellationHandle = Task {
            await recoverFromCancellation()
        }
        await awaitCaughtCancellationStarted()
        caughtCancellationHandle.cancel()
        await caughtCancellationHandle.value
        """)

        guard case .host(let payload)? =
                interpreter.globals.lookup("caughtCancellationHandle"),
              let handle = payload as? RuntimeTaskHandle else {
            Issue.record("expected caught-cancellation task handle")
            return
        }
        #expect(handle.state == .succeeded)
        #expect(handle.result?.stringValue == "caught")
        #expect(handle.isCancelled)
        #expect(handle.cancellation.sources == [.taskHandle])
        #expect(handle.cancellation.isObserved)
        if let requested = handle.cancellation.requestSequence,
           let observed = handle.cancellation.observationSequence {
            #expect(requested < observed)
        } else {
            Issue.record("expected cancellation request and observation sequence")
        }
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func sourceDetachedTaskHasDetachedOwnershipAndNativeBoundary() async throws {
        let interpreter = Interpreter()
        var observedNativeTaskLocal: String?
        var observedRuntimeTaskID: RuntimeTaskID?
        interpreter.globals.define(
            "captureDetachedRuntime",
            .hostFunction(HostFunction(
                name: "captureDetachedRuntime",
                asyncInvoke: { _, context in
                    observedNativeTaskLocal = DetachedRuntimeProbeLocal.value
                    observedRuntimeTaskID =
                        (context as? TaskBoundEvalContext)?
                            .evaluationContext.runtimeTaskID
                    await Task.yield()
                    return .native("detached")
                }
            )))

        try await DetachedRuntimeProbeLocal.$value.withValue("parent") {
            _ = try await interpreter.runAsync(source: """
            let detachedHandle = Task.detached {
                await captureDetachedRuntime()
            }
            """)
        }

        guard case .host(let payload)? =
                interpreter.globals.lookup("detachedHandle"),
              let handle = payload as? RuntimeTaskHandle else {
            Issue.record("expected detached runtime task handle")
            return
        }
        #expect(handle.kind == .detached)
        #expect(handle.parent == nil)
        #expect(handle.state == .succeeded)
        #expect(handle.result?.stringValue == "detached")
        #expect(observedRuntimeTaskID == handle.id)
        #expect(observedNativeTaskLocal == "default")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func runtimeRecordsExplicitInheritedAndDetachedPriorities() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-priority-inheritance.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskPriorityInheritanceProbe()\n"
        let interpreter = Interpreter()
        let value = try await interpreter.runAsync(source: source)
        guard case .instance(let recorder) = value else {
            Issue.record("expected a task-priority recorder instance")
            return
        }

        func handle(_ property: String) throws -> RuntimeTaskHandle {
            let value = try #require(
                recorder.box(for: property)?.value.unwrappedOptionalOrSelf)
            return try #require(value.hostPayload as? RuntimeTaskHandle)
        }

        let parent = try handle("parentTask")
        let child = try handle("childTask")
        let detached = try handle("detachedTask")
        #expect(parent.basePriority.rawValue == TaskPriority.utility.rawValue)
        #expect(parent.effectivePriority == parent.basePriority)
        #expect(child.parent == parent.id)
        #expect(child.basePriority == parent.effectivePriority)
        #expect(detached.parent == nil)
        #expect(detached.basePriority.rawValue == TaskPriority.medium.rawValue)
        #expect(parent.state == .succeeded, "\(parent.failureDescription ?? "")")
        #expect(child.state == .succeeded, "\(child.failureDescription ?? "")")
        #expect(detached.state == .succeeded, "\(detached.failureDescription ?? "")")
        #expect(recorder.box(for: "parent")?.value.intValue
            == Int(TaskPriority.utility.rawValue))
        #expect(recorder.box(for: "child")?.value.intValue
            == Int(TaskPriority.utility.rawValue))
        #expect(recorder.box(for: "detached")?.value.intValue
            == Int(TaskPriority.medium.rawValue))
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func awaitedTaskPriorityEscalatesAndChildInheritsIt() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-priority-escalation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskPriorityEscalationProbe()\n"
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
            Issue.record("expected a priority-escalation recorder")
            return
        }

        func handle(_ property: String) throws -> RuntimeTaskHandle {
            let value = try #require(
                recorder.box(for: property)?.value.unwrappedOptionalOrSelf)
            return try #require(value.hostPayload as? RuntimeTaskHandle)
        }

        let low = try handle("lowTask")
        let high = try handle("highTask")
        let inherited = try handle("inheritedTask")
        #expect(low.basePriority == .background)
        #expect(low.effectivePriority == .high)
        #expect(high.basePriority == .high)
        #expect(inherited.parent == low.id)
        #expect(inherited.basePriority == .high)
        #expect(low.priorityEscalationHistory[high.id] == .high)
        #expect(low.waiterCount == 0)
        #expect(high.waitingOnTaskIDs.isEmpty)
        #expect(recorder.box(for: "before")?.value.intValue
            == Int(TaskPriority.background.rawValue))
        #expect(recorder.box(for: "after")?.value.intValue
            == Int(TaskPriority.high.rawValue))
        #expect(recorder.box(for: "inherited")?.value.intValue
            == Int(TaskPriority.high.rawValue))
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func priorityEscalationPropagatesThroughWaitChain() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(
                "task-priority-transitive-escalation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskPriorityTransitiveProbe()\n"
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
            Issue.record("expected a transitive-priority recorder")
            return
        }

        func handle(_ property: String) throws -> RuntimeTaskHandle {
            let value = try #require(
                recorder.box(for: property)?.value.unwrappedOptionalOrSelf)
            return try #require(value.hostPayload as? RuntimeTaskHandle)
        }

        let bottom = try handle("bottomTask")
        let middle = try handle("middleTask")
        let high = try handle("highTask")
        #expect(bottom.basePriority == .background)
        #expect(bottom.effectivePriority == .high)
        #expect(middle.basePriority == .low)
        #expect(middle.effectivePriority == .high)
        #expect(high.basePriority == .high)
        #expect(middle.priorityEscalationHistory[high.id] == .high)
        #expect(bottom.priorityEscalationHistory[middle.id] == .high)
        #expect(bottom.waiterCount == 0)
        #expect(middle.waiterCount == 0)
        #expect(middle.waitingOnTaskIDs.isEmpty)
        #expect(high.waitingOnTaskIDs.isEmpty)
        #expect(recorder.box(for: "bottomBefore")?.value.intValue
            == Int(TaskPriority.background.rawValue))
        #expect(recorder.box(for: "bottomAfter")?.value.intValue
            == Int(TaskPriority.high.rawValue))
        #expect(recorder.box(for: "middleAfter")?.value.intValue
            == Int(TaskPriority.high.rawValue))
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskLocalStorageIsTaskOwnedInheritedAndCleaned() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-local-inheritance.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait taskLocalInheritanceProbe()\n"
        let interpreter = Interpreter()
        let key = RuntimeTaskLocalKey(rawValue: "AsyncExecutionTests.value")
        var observations: [(RuntimeTaskID, RuntimeTaskKind, String)] = []
        var retainedStorage: [RuntimeTaskID: RuntimeTaskLocalStorage] = [:]
        var recordStorageMatched = true
        interpreter.globals.define(
            "parityYield",
            .hostFunction(HostFunction(
                name: "parityYield",
                asyncInvoke: { arguments, _ in
                    await Task.yield()
                    return arguments.positional(0) ?? .nilValue
                }
            )))
        interpreter.globals.define(
            "parityReadTaskLocal",
            .hostFunction(HostFunction(
                name: "parityReadTaskLocal",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let taskID = bound.evaluationContext.runtimeTaskID,
                          let record = interpreter.concurrencyRuntime
                            .records[taskID] else {
                        throw RuntimeError(message:
                            "task-local read requires a runtime task context")
                    }
                    let storage = bound.evaluationContext.taskLocals
                    retainedStorage[taskID] = storage
                    recordStorageMatched = recordStorageMatched
                        && record.taskLocals === storage
                    let value = context.taskLocalValue(for: key)
                        ?? .native("default")
                    observations.append((
                        taskID, record.kind, value.stringValue ?? "wrong"))
                    return value
                }
            )))
        interpreter.globals.define(
            "parityWithTaskLocalValue",
            .hostFunction(HostFunction(
                name: "parityWithTaskLocalValue",
                asyncInvoke: { arguments, context in
                    guard let value = arguments.positional(0),
                          let operation = arguments.firstUnlabeledClosure else {
                        throw RuntimeError(message:
                            "task-local scope requires a value and operation")
                    }
                    return try await context.withTaskLocalValue(
                        value, for: key, operation: operation, arguments: [])
                }
            )))

        let result = try await interpreter.runAsync(source: source)
        #expect(result.stringValue == "parent,parent:child:parent,default")
        #expect(observations.filter { $0.1 == .root }.map { $0.2 }
            == ["parent"])
        #expect(observations.filter { $0.1 == .unstructured }.map { $0.2 }
            == ["parent", "child", "parent"])
        #expect(observations.filter { $0.1 == .detached }.map { $0.2 }
            == ["default"])
        #expect(retainedStorage.count == 3)
        #expect(Set(retainedStorage.values.map(ObjectIdentifier.init)).count == 3)
        #expect(recordStorageMatched)
        #expect(retainedStorage.values.allSatisfy { $0.isEmpty })
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func sourceTaskLocalDeclarationsUseIdentityAndTaskStorage() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-local-declaration.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait taskLocalDeclarationProbe()\n"
        let interpreter = Interpreter()
        var retainedStorage: [String: RuntimeTaskLocalStorage] = [:]
        var storageCountAtYield: [String: Int] = [:]
        var taskKindAtYield: [String: RuntimeTaskKind] = [:]
        var recordStorageMatched = true
        interpreter.globals.define(
            "parityYield",
            .hostFunction(HostFunction(
                name: "parityYield",
                asyncInvoke: { arguments, context in
                    guard let label = arguments.positional(0)?.stringValue,
                          let bound = context as? TaskBoundEvalContext,
                          let taskID = bound.evaluationContext.runtimeTaskID,
                          let record = interpreter.concurrencyRuntime
                            .records[taskID] else {
                        throw RuntimeError(message:
                            "source task-local yield requires a runtime task")
                    }
                    let storage = bound.evaluationContext.taskLocals
                    retainedStorage[label] = storage
                    storageCountAtYield[label] = storage.count
                    taskKindAtYield[label] = record.kind
                    recordStorageMatched = recordStorageMatched
                        && record.taskLocals === storage
                    await Task.yield()
                    return .native(label)
                }
            )))

        let result = try await interpreter.runAsync(source: source)
        let expected = [
            "primary-default|secondary-default",
            "primary-bound|secondary-default",
            "primary-bound|secondary-sync",
            "primary-bound|secondary-default",
            "primary-default|secondary-default",
            "primary-bound|secondary-bound",
            "primary-bound|secondary-default",
            "primary-default|secondary-default",
        ].joined(separator: ";")
        #expect(result.stringValue == expected)

        let primary = try #require(
            interpreter.enumSymbols["PrimaryTaskLocal"]?
                .taskLocalProperties["value"])
        let secondary = try #require(
            interpreter.enumSymbols["SecondaryTaskLocal"]?
                .taskLocalProperties["value"])
        #expect(primary.key != secondary.key)
        #expect(primary.cachedDefault?.stringValue == "primary-default")
        #expect(secondary.cachedDefault?.stringValue == "secondary-default")

        #expect(storageCountAtYield["source-task-local-inherited"] == 1)
        #expect(storageCountAtYield["source-task-local-detached"] == 0)
        #expect(storageCountAtYield["inside-source-task-local-scope"] == 2)
        #expect(taskKindAtYield["source-task-local-inherited"] == .unstructured)
        #expect(taskKindAtYield["source-task-local-detached"] == .detached)
        #expect(taskKindAtYield["inside-source-task-local-scope"] == .root)
        #expect(retainedStorage.count == 3)
        #expect(Set(retainedStorage.values.map(ObjectIdentifier.init)).count == 3)
        #expect(recordStorageMatched)
        #expect(retainedStorage.values.allSatisfy { $0.isEmpty })
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskLocalProjectionGetReadsBindingAndDefault() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        enum Local {
            @TaskLocal static var value: Int = 3
        }
        func probe() -> String {
            let before = "\\(Local.$value.get())|\\(Local.$value)"
            let inside = Local.$value.withValue(9) {
                "\\(Local.$value.get())|\\(Local.$value)"
            }
            let after = "\\(Local.$value.get())|\\(Local.$value)"
            return "\\(before);\\(inside);\\(after)"
        }
        probe()
        """)

        #expect(result.stringValue == [
            "3|TaskLocal<Int>(defaultValue: 3)",
            "9|TaskLocal<Int>(defaultValue: 3)",
            "3|TaskLocal<Int>(defaultValue: 3)",
        ].joined(separator: ";"))
    }

    @Test func nestedAsyncLetsInheritTaskLocalAndCleanOwnership() async throws {
        let interpreter = Interpreter()
        var observedNestedOwnership = false
        var retainedStorage: [RuntimeTaskLocalStorage] = []
        interpreter.globals.define(
            "inspectNestedTaskLocalAsyncLet",
            .hostFunction(HostFunction(
                name: "inspectNestedTaskLocalAsyncLet",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let leafID = bound.evaluationContext.runtimeTaskID,
                          let leaf = interpreter.concurrencyRuntime.records[leafID],
                          let parentID = leaf.parent,
                          let parent = interpreter.concurrencyRuntime.records[parentID],
                          let rootID = parent.parent,
                          let root = interpreter.concurrencyRuntime.records[rootID],
                          let key = interpreter.enumSymbols["Local"]?
                            .taskLocalProperties["value"]?.key,
                          let parentScope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.ownerTaskID == rootID
                                    && $0.childTaskIDs.contains(parentID)
                            }),
                          let leafScope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.ownerTaskID == parentID
                                    && $0.childTaskIDs.contains(leafID)
                            }) else {
                        throw RuntimeError(message:
                            "nested async-let task-local ownership was incomplete")
                    }
                    retainedStorage = [
                        root.taskLocals, parent.taskLocals, leaf.taskLocals,
                    ]
                    observedNestedOwnership = leaf.kind == .asyncLet
                        && parent.kind == .asyncLet
                        && parentScope.id != leafScope.id
                        && parent.taskLocals.value(for: key)?.intValue == 2
                        && leaf.taskLocals.value(for: key)?.intValue == 2
                        && root.taskLocals !== parent.taskLocals
                        && parent.taskLocals !== leaf.taskLocals
                    await Task.yield()
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        enum Local {
            @TaskLocal static var value: Int = 0
        }
        func leaf() async -> Int {
            await inspectNestedTaskLocalAsyncLet()
            return Local.$value.get()
        }
        func parent() async -> Int {
            async let value = leaf()
            return await value
        }
        func root() async -> Int {
            await Local.$value.withValue(2) {
                async let value = parent()
                return await value
            }
        }
        await root()
        """)

        #expect(result.intValue == 2)
        #expect(observedNestedOwnership)
        #expect(retainedStorage.count == 3)
        #expect(Set(retainedStorage.map(ObjectIdentifier.init)).count == 3)
        #expect(retainedStorage.allSatisfy { $0.isEmpty })
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.structuredScopes.isEmpty)
        #expect(interpreter.concurrencyRuntime.taskGroups.isEmpty)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func taskAsyncLetAndGroupChildComposeOwnershipAndTaskLocals()
    async throws {
        let interpreter = Interpreter()
        var observedBindings = false
        var observedRecords: [RuntimeTaskRecord] = []
        var observedAsyncLetScope: RuntimeStructuredScopeRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var retainedStorage: [RuntimeTaskLocalStorage] = []
        interpreter.globals.define(
            "inspectTaskAsyncLetGroupComposition",
            .hostFunction(HostFunction(
                name: "inspectTaskAsyncLetGroupComposition",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let groupChildID = bound.evaluationContext.runtimeTaskID,
                          let groupChild = interpreter.concurrencyRuntime
                            .records[groupChildID],
                          let groupID = groupChild.taskGroupID,
                          let group = interpreter.concurrencyRuntime
                            .taskGroups[groupID],
                          let asyncLet = interpreter.concurrencyRuntime
                            .records[group.ownerTaskID],
                          let taskID = asyncLet.parent,
                          let task = interpreter.concurrencyRuntime.records[taskID],
                          let rootID = task.parent,
                          let root = interpreter.concurrencyRuntime.records[rootID],
                          let asyncLetScope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.kind == .asyncLet
                                    && $0.ownerTaskID == taskID
                                    && $0.childTaskIDs.contains(asyncLet.id)
                            }),
                          let oneKey = interpreter.enumSymbols["Local"]?
                            .taskLocalProperties["one"]?.key,
                          let twoKey = interpreter.enumSymbols["Local"]?
                            .taskLocalProperties["two"]?.key else {
                        throw RuntimeError(message:
                            "Task/async-let/group composition lost ownership")
                    }

                    observedRecords = [root, task, asyncLet, groupChild]
                    observedAsyncLetScope = asyncLetScope
                    observedGroup = group
                    retainedStorage = observedRecords.map(\.taskLocals)
                    observedBindings = root.taskLocals.value(for: oneKey)?.intValue == 11
                        && task.taskLocals.value(for: oneKey)?.intValue == 11
                        && asyncLet.taskLocals.value(for: oneKey)?.intValue == 11
                        && groupChild.taskLocals.value(for: oneKey)?.intValue == 11
                        && root.taskLocals.value(for: twoKey) == nil
                        && task.taskLocals.value(for: twoKey) == nil
                        && asyncLet.taskLocals.value(for: twoKey) == nil
                        && groupChild.taskLocals.value(for: twoKey)?.intValue == 22
                    await Task.yield()
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        enum Local {
            @TaskLocal static var one: Int = 1
            @TaskLocal static var two: Int = 2
        }
        func composedGroupChild() async -> Int {
            await inspectTaskAsyncLetGroupComposition()
            return Local.one + Local.two
        }
        func composedOwner() async -> Int {
            await Local.$one.withValue(11) {
                let task = Task {
                    async let value: Int = await withTaskGroup(
                        of: Int.self
                    ) { group in
                        Local.$two.withValue(22) {
                            group.addTask {
                                await composedGroupChild()
                            }
                        }
                        return await group.next() ?? -1
                    }
                    return await value
                }
                return await task.value
            }
        }
        await composedOwner()
        """)

        let root = try #require(observedRecords.first)
        let task = try #require(observedRecords.dropFirst().first)
        let asyncLet = try #require(observedRecords.dropFirst(2).first)
        let groupChild = try #require(observedRecords.dropFirst(3).first)
        let asyncLetScope = try #require(observedAsyncLetScope)
        let group = try #require(observedGroup)
        #expect(result.intValue == 33)
        #expect(observedBindings)
        #expect(root.kind == .root)
        #expect(task.kind == .unstructured)
        #expect(asyncLet.kind == .asyncLet)
        #expect(groupChild.kind == .groupChild)
        #expect(task.parent == root.id)
        #expect(asyncLet.parent == task.id)
        #expect(groupChild.parent == asyncLet.id)
        #expect(asyncLetScope.ownerTaskID == task.id)
        #expect(asyncLetScope.childTaskIDs == [asyncLet.id])
        #expect(group.ownerTaskID == asyncLet.id)
        #expect(group.structuredScope.ownerTaskID == asyncLet.id)
        #expect(group.structuredScope.childTaskIDs == [groupChild.id])
        #expect(group.completedChildTaskIDs == [groupChild.id])
        #expect(group.consumedChildTaskIDs == [groupChild.id])
        #expect(Set(retainedStorage.map(ObjectIdentifier.init)).count == 4)
        #expect(retainedStorage.allSatisfy { $0.isEmpty })
        #expect(observedRecords.allSatisfy {
            $0.evaluationContext == nil && $0.nativeDriver == nil
        })
        #expect(interpreter.concurrencyRuntime.records.isEmpty)
        #expect(interpreter.concurrencyRuntime.structuredScopes.isEmpty)
        #expect(interpreter.concurrencyRuntime.taskGroups.isEmpty)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func runtimeTaskHandleDispatchesCancellableExtensions() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        protocol Cancellable {}
        extension Cancellable {
            func lifecycleName() -> String { "cancellable" }
        }
        let handle = Task {}
        handle.lifecycleName()
        """)

        #expect(result.stringValue == "cancellable")
    }

    @Test func asyncLetChildBelongsToLexicalStructuredScope() async throws {
        let interpreter = Interpreter()
        var observedKind: RuntimeTaskKind?
        var observedParentSuspension: RuntimeSuspension?
        var scopeOwnedChild = false
        var sessionOwnedChild = true
        interpreter.globals.define(
            "inspectAsyncLetChild",
            .hostFunction(HostFunction(
                name: "inspectAsyncLetChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let parentID = child.parent,
                          let parent = interpreter.concurrencyRuntime
                            .records[parentID],
                          let scope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.ownerTaskID == parentID
                            }) else {
                        throw RuntimeError(message:
                            "async-let child lost structured ownership")
                    }
                    observedKind = child.kind
                    observedParentSuspension = parent.suspension
                    scopeOwnedChild = scope.childTaskIDs.contains(childID)
                        && parent.structuredScopes.contains(scope.id)
                        && parent.structuredChildren.contains(childID)
                    sessionOwnedChild = interpreter.scheduledTasks.contains {
                        $0.id == childID
                    }
                    await Task.yield()
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        func asyncLetChild() async -> String {
            await inspectAsyncLetChild()
            return "value"
        }
        func asyncLetOwner() async -> String {
            async let value = asyncLetChild()
            return await value
        }
        await asyncLetOwner()
        """)

        #expect(result.stringValue == "value")
        #expect(observedKind == .asyncLet)
        if case .awaitingTask = observedParentSuspension {
            // The binding read, rather than session drain, joined the child.
        } else {
            Issue.record("async-let parent did not suspend on its child")
        }
        #expect(scopeOwnedChild)
        #expect(!sessionOwnedChild)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingAsyncLetScopePreservesLexicalCleanupOrder()
    async throws {
        let interpreter = Interpreter()
        var observedChildren: [RuntimeTaskRecord] = []
        var observedScopes: [RuntimeStructuredScopeRecord] = []
        var observedOwners: [RuntimeTaskRecord] = []
        interpreter.globals.define(
            "inspectThrowingAsyncLetDeferChild",
            .hostFunction(HostFunction(
                name: "inspectThrowingAsyncLetDeferChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let ownerID = child.parent,
                          let owner = interpreter.concurrencyRuntime
                            .records[ownerID],
                          let scope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.childTaskIDs.contains(childID)
                            }) else {
                        throw RuntimeError(message:
                            "throwing async-let defer lost runtime ownership")
                    }
                    observedChildren.append(child)
                    observedScopes.append(scope)
                    observedOwners.append(owner)
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        enum ThrowingAsyncLetDeferError: Error {
            case failed
        }
        @MainActor
        final class ThrowingAsyncLetDeferRecorder {
            var events: [String] = []
            var childStarted = false
        }
        @MainActor
        func throwingAsyncLetDeferChild(
            _ recorder: ThrowingAsyncLetDeferRecorder
        ) async -> String {
            recorder.events.append("child-start")
            recorder.childStarted = true
            do {
                try await Task.sleep(for: .seconds(30))
                recorder.events.append("child-finished")
            } catch is CancellationError {
                await inspectThrowingAsyncLetDeferChild()
                recorder.events.append("child-cancelled")
            } catch {
                recorder.events.append("wrong-child-error")
            }
            return "unused"
        }
        @MainActor
        func throwWithDeferBeforeAsyncLet(
            _ recorder: ThrowingAsyncLetDeferRecorder
        ) async throws {
            defer {
                recorder.events.append("defer")
            }
            async let unused = throwingAsyncLetDeferChild(recorder)
            while !recorder.childStarted {
                await Task.yield()
            }
            recorder.events.append("scope-throw")
            throw ThrowingAsyncLetDeferError.failed
        }
        @MainActor
        func throwWithDeferAfterAsyncLet(
            _ recorder: ThrowingAsyncLetDeferRecorder
        ) async throws {
            async let unused = throwingAsyncLetDeferChild(recorder)
            defer {
                recorder.events.append("defer")
            }
            while !recorder.childStarted {
                await Task.yield()
            }
            recorder.events.append("scope-throw")
            throw ThrowingAsyncLetDeferError.failed
        }
        @MainActor
        func throwingDeferBeforeAsyncLetProbe() async -> String {
            let recorder = ThrowingAsyncLetDeferRecorder()
            do {
                try await throwWithDeferBeforeAsyncLet(recorder)
                recorder.events.append("missed")
            } catch ThrowingAsyncLetDeferError.failed {
                recorder.events.append("caught")
            } catch {
                recorder.events.append("wrong-error")
            }
            return recorder.events.joined(separator: ",")
        }
        @MainActor
        func throwingDeferAfterAsyncLetProbe() async -> String {
            let recorder = ThrowingAsyncLetDeferRecorder()
            do {
                try await throwWithDeferAfterAsyncLet(recorder)
                recorder.events.append("missed")
            } catch ThrowingAsyncLetDeferError.failed {
                recorder.events.append("caught")
            } catch {
                recorder.events.append("wrong-error")
            }
            return recorder.events.joined(separator: ",")
        }
        let before = await throwingDeferBeforeAsyncLetProbe()
        let after = await throwingDeferAfterAsyncLetProbe()
        before + "|" + after
        """)

        #expect(result.stringValue == "child-start,scope-throw,"
            + "child-cancelled,defer,caught|child-start,scope-throw,"
            + "defer,child-cancelled,caught")
        #expect(observedChildren.count == 2)
        #expect(observedChildren.allSatisfy { child in
            child.kind == .asyncLet
                && child.state == .succeeded
                && child.cancellation.sources == [.structuredScopeExit]
                && child.cancellation.isObserved
        })
        #expect(observedScopes.count == 2)
        #expect(observedScopes.allSatisfy { scope in
            scope.kind == .asyncLet && scope.childTaskIDs.count == 1
        })
        #expect(observedOwners.count == 2)
        #expect(observedOwners.allSatisfy { owner in
            !owner.cancellation.isRequested
                && !owner.cancellation.isObserved
        })
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func earlyReturnAsyncLetScopePreservesLexicalCleanupOrder()
    async throws {
        let interpreter = Interpreter()
        var observedChildren: [RuntimeTaskRecord] = []
        var observedScopes: [RuntimeStructuredScopeRecord] = []
        var observedOwners: [RuntimeTaskRecord] = []
        interpreter.globals.define(
            "inspectEarlyReturnAsyncLetDeferChild",
            .hostFunction(HostFunction(
                name: "inspectEarlyReturnAsyncLetDeferChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let ownerID = child.parent,
                          let owner = interpreter.concurrencyRuntime
                            .records[ownerID],
                          let scope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.childTaskIDs.contains(childID)
                            }) else {
                        throw RuntimeError(message:
                            "early-return async-let defer lost ownership")
                    }
                    observedChildren.append(child)
                    observedScopes.append(scope)
                    observedOwners.append(owner)
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        final class EarlyReturnAsyncLetDeferRecorder {
            var events: [String] = []
            var childStarted = false
        }
        @MainActor
        func earlyReturnAsyncLetDeferChild(
            _ recorder: EarlyReturnAsyncLetDeferRecorder
        ) async -> String {
            recorder.events.append("child-start")
            recorder.childStarted = true
            do {
                try await Task.sleep(for: .seconds(30))
                recorder.events.append("child-finished")
            } catch is CancellationError {
                await inspectEarlyReturnAsyncLetDeferChild()
                recorder.events.append("child-cancelled")
            } catch {
                recorder.events.append("wrong-child-error")
            }
            return "unused"
        }
        @MainActor
        func returnWithDeferBeforeAsyncLet(
            _ recorder: EarlyReturnAsyncLetDeferRecorder
        ) async -> String {
            defer {
                recorder.events.append("defer")
            }
            async let unused = earlyReturnAsyncLetDeferChild(recorder)
            while !recorder.childStarted {
                await Task.yield()
            }
            recorder.events.append("early-return")
            return "returned"
        }
        @MainActor
        func returnWithDeferAfterAsyncLet(
            _ recorder: EarlyReturnAsyncLetDeferRecorder
        ) async -> String {
            async let unused = earlyReturnAsyncLetDeferChild(recorder)
            defer {
                recorder.events.append("defer")
            }
            while !recorder.childStarted {
                await Task.yield()
            }
            recorder.events.append("early-return")
            return "returned"
        }
        @MainActor
        func earlyReturnDeferBeforeAsyncLetProbe() async -> String {
            let recorder = EarlyReturnAsyncLetDeferRecorder()
            let value = await returnWithDeferBeforeAsyncLet(recorder)
            recorder.events.append(value)
            return recorder.events.joined(separator: ",")
        }
        @MainActor
        func earlyReturnDeferAfterAsyncLetProbe() async -> String {
            let recorder = EarlyReturnAsyncLetDeferRecorder()
            let value = await returnWithDeferAfterAsyncLet(recorder)
            recorder.events.append(value)
            return recorder.events.joined(separator: ",")
        }
        let before = await earlyReturnDeferBeforeAsyncLetProbe()
        let after = await earlyReturnDeferAfterAsyncLetProbe()
        before + "|" + after
        """)

        #expect(result.stringValue == "child-start,early-return,"
            + "child-cancelled,defer,returned|child-start,early-return,"
            + "defer,child-cancelled,returned")
        #expect(observedChildren.count == 2)
        #expect(observedChildren.allSatisfy { child in
            child.kind == .asyncLet
                && child.state == .succeeded
                && child.cancellation.sources == [.structuredScopeExit]
                && child.cancellation.isObserved
        })
        #expect(observedScopes.count == 2)
        #expect(observedScopes.allSatisfy { scope in
            scope.kind == .asyncLet && scope.childTaskIDs.count == 1
        })
        #expect(observedOwners.count == 2)
        #expect(observedOwners.allSatisfy { owner in
            !owner.cancellation.isRequested
                && !owner.cancellation.isObserved
        })
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func cancelledAsyncLetScopePreservesLexicalCleanupOrder()
    async throws {
        let interpreter = Interpreter()
        var observedChildren: [RuntimeTaskRecord] = []
        var observedScopes: [RuntimeStructuredScopeRecord] = []
        var observedOwners: [RuntimeTaskRecord] = []
        interpreter.globals.define(
            "inspectCancellationAsyncLetDeferChild",
            .hostFunction(HostFunction(
                name: "inspectCancellationAsyncLetDeferChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let ownerID = child.parent,
                          let owner = interpreter.concurrencyRuntime
                            .records[ownerID],
                          let scope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.childTaskIDs.contains(childID)
                            }) else {
                        throw RuntimeError(message:
                            "cancelled async-let defer lost ownership")
                    }
                    observedChildren.append(child)
                    observedScopes.append(scope)
                    observedOwners.append(owner)
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        final class CancellationAsyncLetDeferRecorder {
            var events: [String] = []
            var childStarted = false
            var ownerWaiting = false
            var scopeExitReached = false
            var releaseChild = false
            var childCaughtCancellation = false
            var ownerCaughtCancellation = false
            var ownerWasCancelled = false
        }
        @MainActor
        func cancellationAsyncLetDeferChild(
            _ recorder: CancellationAsyncLetDeferRecorder
        ) async -> String {
            recorder.childStarted = true
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                recorder.childCaughtCancellation = true
                await inspectCancellationAsyncLetDeferChild()
                while !recorder.releaseChild {
                    await Task.yield()
                }
                recorder.events.append("child-complete")
            } catch {
                recorder.events.append("wrong-child-error")
            }
            return "unused"
        }
        @MainActor
        func cancelWithDeferBeforeAsyncLet(
            _ recorder: CancellationAsyncLetDeferRecorder
        ) async -> String {
            defer {
                recorder.events.append("defer")
            }
            async let unused = cancellationAsyncLetDeferChild(recorder)
            while !recorder.childStarted {
                await Task.yield()
            }
            recorder.ownerWaiting = true
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                recorder.ownerCaughtCancellation = true
            } catch {
                recorder.events.append("wrong-owner-error")
            }
            recorder.ownerWasCancelled = Task.isCancelled
            recorder.scopeExitReached = true
            recorder.events.append("scope-exit")
            return "returned"
        }
        @MainActor
        func cancelWithDeferAfterAsyncLet(
            _ recorder: CancellationAsyncLetDeferRecorder
        ) async -> String {
            async let unused = cancellationAsyncLetDeferChild(recorder)
            defer {
                recorder.events.append("defer")
            }
            while !recorder.childStarted {
                await Task.yield()
            }
            recorder.ownerWaiting = true
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                recorder.ownerCaughtCancellation = true
            } catch {
                recorder.events.append("wrong-owner-error")
            }
            recorder.ownerWasCancelled = Task.isCancelled
            recorder.scopeExitReached = true
            recorder.events.append("scope-exit")
            return "returned"
        }
        @MainActor
        func runCancellationDeferOrderVariant(
            deferBefore: Bool
        ) async -> String {
            let recorder = CancellationAsyncLetDeferRecorder()
            let owner = Task {
                if deferBefore {
                    return await cancelWithDeferBeforeAsyncLet(recorder)
                }
                return await cancelWithDeferAfterAsyncLet(recorder)
            }
            while !recorder.ownerWaiting {
                await Task.yield()
            }
            owner.cancel()
            while !recorder.scopeExitReached {
                await Task.yield()
            }
            recorder.releaseChild = true
            let value = await owner.value
            recorder.events.append(value)
            let cancellation = recorder.childCaughtCancellation
                && recorder.ownerCaughtCancellation
                && recorder.ownerWasCancelled
                && owner.isCancelled
                ? "cancelled"
                : "wrong-cancellation"
            return recorder.events.joined(separator: ",")
                + ":" + cancellation
        }
        let before = await runCancellationDeferOrderVariant(deferBefore: true)
        let after = await runCancellationDeferOrderVariant(deferBefore: false)
        before + "|" + after
        """)

        #expect(result.stringValue == "scope-exit,child-complete,"
            + "defer,returned:cancelled|scope-exit,defer,"
            + "child-complete,returned:cancelled")
        #expect(observedChildren.count == 2)
        #expect(observedChildren.allSatisfy { child in
            child.kind == .asyncLet
                && child.state == .succeeded
                && child.cancellation.sources
                    == [.structuredParent, .structuredScopeExit]
                && child.cancellation.isObserved
        })
        #expect(observedScopes.count == 2)
        #expect(observedScopes.allSatisfy { scope in
            scope.kind == .asyncLet && scope.childTaskIDs.count == 1
        })
        #expect(observedOwners.count == 2)
        #expect(observedOwners.allSatisfy { owner in
            owner.kind == .unstructured
                && owner.state == .succeeded
                && owner.cancellation.sources == [.taskHandle]
                && owner.cancellation.isObserved
        })
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func asyncLetTuplePatternProjectsOneStructuredChild() async throws {
        let interpreter = Interpreter()
        var observedChildCount = 0
        var observedScopeChildCount = 0
        interpreter.globals.define(
            "inspectAsyncLetTupleChild",
            .hostFunction(HostFunction(
                name: "inspectAsyncLetTupleChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime.records[childID],
                          let parentID = child.parent,
                          let parent = interpreter.concurrencyRuntime.records[parentID],
                          let scope = interpreter.concurrencyRuntime
                            .structuredScopes.values.first(where: {
                                $0.ownerTaskID == parentID
                            }) else {
                        throw RuntimeError(message:
                            "tuple async-let child lost structured ownership")
                    }
                    observedChildCount = parent.structuredChildren.count
                    observedScopeChildCount = scope.childTaskIDs.count
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        func asyncLetTupleChild() async -> (String, String) {
            await inspectAsyncLetTupleChild()
            return ("left", "right")
        }
        func asyncLetTupleOwner() async -> String {
            async let (left, right) = asyncLetTupleChild()
            let first = await left
            let second = await right
            return first + ":" + second
        }
        await asyncLetTupleOwner()
        """)

        #expect(result.stringValue == "left:right")
        #expect(observedChildCount == 1)
        #expect(observedScopeChildCount == 1)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func asyncLetReadWithoutAwaitIsDiagnosedAndCleanedUp() async {
        let interpreter = Interpreter()
        do {
            _ = try await interpreter.runAsync(source: """
            func asyncLetDiagnosticValue() async -> String {
                await Task.yield()
                return "value"
            }
            func asyncLetMissingAwait() async -> String {
                async let value = asyncLetDiagnosticValue()
                return value
            }
            await asyncLetMissingAwait()
            """)
            Issue.record("async-let read without await unexpectedly succeeded")
        } catch let failure as RuntimeError {
            #expect(failure.message.contains(
                "async let binding 'value' requires await"))
        } catch {
            Issue.record("unexpected async-let diagnostic: \(error)")
        }

        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskGroupWaitForAllUsesStructuredGroupSuspension() async throws {
        let interpreter = Interpreter()
        var observedKind: RuntimeTaskKind?
        var observedParentSuspension: RuntimeSuspension?
        var observedGroupID: RuntimeTaskGroupID?
        var scopeOwnedChild = false
        var sessionOwnedChild = true
        interpreter.globals.define(
            "inspectTaskGroupChild",
            .hostFunction(HostFunction(
                name: "inspectTaskGroupChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let parentID = child.parent,
                          let parent = interpreter.concurrencyRuntime
                            .records[parentID],
                          let group = interpreter.concurrencyRuntime
                            .taskGroups.values.first(where: {
                                $0.childTaskIDs.contains(childID)
                            }) else {
                        throw RuntimeError(message:
                            "task-group child lost structured ownership")
                    }

                    for _ in 0..<1_000 {
                        if case .waitingForGroup(let groupID)? =
                            parent.suspension,
                           groupID == group.id {
                            observedParentSuspension = parent.suspension
                            observedGroupID = groupID
                            break
                        }
                        await Task.yield()
                    }
                    observedKind = child.kind
                    let scope = group.structuredScope
                    scopeOwnedChild = scope.kind == .taskGroup
                        && scope.childTaskIDs.contains(childID)
                        && parent.structuredScopes.contains(scope.id)
                        && parent.structuredChildren.contains(childID)
                    sessionOwnedChild = interpreter.scheduledTasks.contains {
                        $0.id == childID
                    }
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        func inspectedTaskGroupChild() async -> String {
            await inspectTaskGroupChild()
            return "value"
        }
        func inspectedTaskGroupOwner() async -> String {
            await withTaskGroup(of: String.self) { group in
                group.addTask {
                    await inspectedTaskGroupChild()
                }
                await group.waitForAll()
            }
            return "done"
        }
        await inspectedTaskGroupOwner()
        """)

        #expect(result.stringValue == "done")
        #expect(observedKind == .groupChild)
        #expect(observedGroupID != nil)
        if case .waitingForGroup = observedParentSuspension {
            // The source owner waits on the logical group, not host/session
            // draining or one exposed task handle.
        } else {
            Issue.record("task-group owner did not suspend on its group")
        }
        #expect(scopeOwnedChild)
        #expect(!sessionOwnedChild)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskGroupChildOwnsNestedGroupAndGrandchild() async throws {
        let interpreter = Interpreter()
        var observedOuterOwner: RuntimeTaskRecord?
        var observedOuterChild: RuntimeTaskRecord?
        var observedGrandchild: RuntimeTaskRecord?
        var observedOuterGroup: RuntimeTaskGroupRecord?
        var observedInnerGroup: RuntimeTaskGroupRecord?
        interpreter.globals.define(
            "inspectNestedTaskGroupGrandchild",
            .hostFunction(HostFunction(
                name: "inspectNestedTaskGroupGrandchild"
            ) { _, _ in
                guard let grandchildID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let grandchild = interpreter.concurrencyRuntime
                        .records[grandchildID],
                      let innerGroupID = grandchild.taskGroupID,
                      let innerGroup = interpreter.concurrencyRuntime
                        .taskGroups[innerGroupID],
                      let outerChild = interpreter.concurrencyRuntime
                        .records[innerGroup.ownerTaskID],
                      let outerGroupID = outerChild.taskGroupID,
                      let outerGroup = interpreter.concurrencyRuntime
                        .taskGroups[outerGroupID],
                      let outerOwner = interpreter.concurrencyRuntime
                        .records[outerGroup.ownerTaskID] else {
                    throw RuntimeError(message:
                        "nested task-group child lost runtime ownership")
                }
                observedOuterOwner = outerOwner
                observedOuterChild = outerChild
                observedGrandchild = grandchild
                observedOuterGroup = outerGroup
                observedInnerGroup = innerGroup
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        func nestedTaskGroupGrandchild() async -> String {
            inspectNestedTaskGroupGrandchild()
            await Task.yield()
            return "value"
        }
        func nestedTaskGroupOwner() async -> String {
            await withTaskGroup(of: String.self) { outerGroup in
                outerGroup.addTask {
                    await withTaskGroup(of: String.self) { innerGroup in
                        innerGroup.addTask {
                            await nestedTaskGroupGrandchild()
                        }
                        return await innerGroup.next() ?? "inner-missing"
                    }
                }
                return await outerGroup.next() ?? "outer-missing"
            }
        }
        await nestedTaskGroupOwner()
        """)

        let outerOwner = try #require(observedOuterOwner)
        let outerChild = try #require(observedOuterChild)
        let grandchild = try #require(observedGrandchild)
        let outerGroup = try #require(observedOuterGroup)
        let innerGroup = try #require(observedInnerGroup)
        #expect(result.stringValue == "value")
        #expect(outerGroup.kind == .nonthrowing)
        #expect(innerGroup.kind == .nonthrowing)
        #expect(outerGroup.ownerTaskID == outerOwner.id)
        #expect(outerGroup.childTaskIDs == [outerChild.id])
        #expect(outerGroup.structuredScope.ownerTaskID == outerOwner.id)
        #expect(innerGroup.ownerTaskID == outerChild.id)
        #expect(innerGroup.childTaskIDs == [grandchild.id])
        #expect(innerGroup.structuredScope.ownerTaskID == outerChild.id)
        #expect(outerChild.kind == .groupChild)
        #expect(outerChild.parent == outerOwner.id)
        #expect(outerChild.structuredChildren == [grandchild.id])
        #expect(grandchild.kind == .groupChild)
        #expect(grandchild.parent == outerChild.id)
        #expect(outerGroup.completedChildTaskIDs == [outerChild.id])
        #expect(outerGroup.consumedChildTaskIDs == [outerChild.id])
        #expect(innerGroup.completedChildTaskIDs == [grandchild.id])
        #expect(innerGroup.consumedChildTaskIDs == [grandchild.id])
        #expect(outerGroup.pendingCompletedChildCount == 0)
        #expect(innerGroup.pendingCompletedChildCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskGroupChildAddedAfterCancelAllStartsCancelled() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        func taskGroupCancellationLabel(_ isCancelled: Bool) -> String {
            if isCancelled {
                return "cancelled"
            }
            return "active"
        }
        func taskGroupAddDecisionLabel(_ added: Bool) -> String {
            if added {
                return "added"
            }
            return "skipped"
        }
        await withTaskGroup(of: String.self) { group in
            let before = taskGroupCancellationLabel(group.isCancelled)
            group.cancelAll()
            let after = taskGroupCancellationLabel(group.isCancelled)
            let conditional = taskGroupAddDecisionLabel(
                group.addTaskUnlessCancelled {
                    return "wrong-conditional"
                })
            group.addTask {
                if Task.isCancelled {
                    return "cancelled"
                }
                return "active"
            }
            let child = await group.next() ?? "empty"
            return before + ":" + after + ":" + conditional + ":" + child
        }
        """)

        #expect(result.stringValue == "active:cancelled:skipped:cancelled")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskGroupBodyDeferCancelsBeforeImplicitJoin() async throws {
        let interpreter = Interpreter()
        var observedChild: RuntimeTaskRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?
        interpreter.globals.define(
            "inspectTaskGroupDeferCleanup",
            .hostFunction(HostFunction(
                name: "inspectTaskGroupDeferCleanup"
            ) { _, _ in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let child = interpreter.concurrencyRuntime
                        .records[childID],
                      let groupID = child.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID],
                      let owner = interpreter.concurrencyRuntime
                        .records[group.ownerTaskID] else {
                    throw RuntimeError(message:
                        "task-group defer cleanup lost runtime ownership")
                }
                observedChild = child
                observedGroup = group
                observedOwner = owner
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        var deferCleanupEvents: [String] = []
        @MainActor
        var deferCleanupChildStarted = false
        @MainActor
        func deferCleanupChild() async -> String {
            deferCleanupChildStarted = true
            deferCleanupEvents.append("child-start")
            do {
                try await Task.sleep(for: .seconds(30))
                deferCleanupEvents.append("child-finished")
                return "finished"
            } catch {
                inspectTaskGroupDeferCleanup()
                let state = Task.isCancelled
                    ? "child-cancelled"
                    : "child-error"
                deferCleanupEvents.append(state)
                return state
            }
        }
        @MainActor
        func deferCleanupOwner() async -> String {
            await withTaskGroup(of: String.self) { group in
                group.addTask {
                    await deferCleanupChild()
                }
                while !deferCleanupChildStarted {
                    await Task.yield()
                }
                defer {
                    deferCleanupEvents.append("defer-cancel")
                    group.cancelAll()
                }
                deferCleanupEvents.append("body-return")
            }
            deferCleanupEvents.append("after-scope")
            return deferCleanupEvents.joined(separator: ",")
        }
        await deferCleanupOwner()
        """)

        #expect(result.stringValue
            == "child-start,body-return,defer-cancel,child-cancelled,after-scope")
        #expect(observedGroup?.kind == .nonthrowing)
        #expect(observedGroup?.hasCancelAllRequest == true)
        #expect(observedGroup?.completedChildTaskIDs.count == 1)
        #expect(observedGroup?.consumedChildTaskIDs.isEmpty == true)
        #expect(observedGroup?.pendingCompletedChildCount == 1)
        #expect(observedChild?.kind == .groupChild)
        #expect(observedChild?.state == .succeeded)
        #expect(observedChild?.cancellation.sources == [.taskGroupCancelAll])
        #expect(observedChild?.cancellation.isObserved == true)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupBodyDeferRunsBeforeExceptionalCleanup()
    async throws {
        let interpreter = Interpreter()
        var observedChild: RuntimeTaskRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?
        interpreter.globals.define(
            "inspectThrowingTaskGroupDeferCleanup",
            .hostFunction(HostFunction(
                name: "inspectThrowingTaskGroupDeferCleanup"
            ) { _, _ in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let child = interpreter.concurrencyRuntime
                        .records[childID],
                      let groupID = child.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID],
                      let owner = interpreter.concurrencyRuntime
                        .records[group.ownerTaskID] else {
                    throw RuntimeError(message:
                        "throwing task-group defer cleanup lost runtime ownership")
                }
                observedChild = child
                observedGroup = group
                observedOwner = owner
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        enum ThrowingDeferCleanupError: Error {
            case failed
        }
        @MainActor
        var throwingDeferEvents: [String] = []
        @MainActor
        var throwingDeferChildStarted = false
        @MainActor
        func throwingDeferChild() async -> String {
            throwingDeferChildStarted = true
            throwingDeferEvents.append("child-start")
            do {
                try await Task.sleep(for: .seconds(30))
                throwingDeferEvents.append("child-finished")
                return "finished"
            } catch {
                inspectThrowingTaskGroupDeferCleanup()
                let state = Task.isCancelled
                    ? "child-cancelled"
                    : "child-error"
                throwingDeferEvents.append(state)
                return state
            }
        }
        @MainActor
        func throwingDeferOwner() async -> String {
            do {
                _ = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask {
                        await throwingDeferChild()
                    }
                    while !throwingDeferChildStarted {
                        await Task.yield()
                    }
                    defer {
                        throwingDeferEvents.append("defer")
                    }
                    throwingDeferEvents.append("body-throw")
                    throw ThrowingDeferCleanupError.failed
                }
                throwingDeferEvents.append("missed")
            } catch ThrowingDeferCleanupError.failed {
                throwingDeferEvents.append("caught-body")
            } catch {
                throwingDeferEvents.append("wrong-error")
            }
            return throwingDeferEvents.joined(separator: ",")
        }
        await throwingDeferOwner()
        """)

        #expect(result.stringValue
            == "child-start,body-throw,defer,child-cancelled,caught-body")
        #expect(observedGroup?.kind == .throwing)
        #expect(observedGroup?.hasCancelAllRequest == false)
        #expect(observedGroup?.completedChildTaskIDs.count == 1)
        #expect(observedGroup?.consumedChildTaskIDs.isEmpty == true)
        #expect(observedGroup?.pendingCompletedChildCount == 1)
        #expect(observedChild?.kind == .groupChild)
        #expect(observedChild?.state == .succeeded)
        #expect(observedChild?.cancellation.sources == [.structuredScopeExit])
        #expect(observedChild?.cancellation.isObserved == true)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func ownerCancelledTaskGroupBodyDeferRunsBeforeImplicitJoin()
    async throws {
        let interpreter = Interpreter()
        var observedChild: RuntimeTaskRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?
        interpreter.globals.define(
            "inspectOwnerCancelledTaskGroupDeferCleanup",
            .hostFunction(HostFunction(
                name: "inspectOwnerCancelledTaskGroupDeferCleanup"
            ) { _, _ in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let child = interpreter.concurrencyRuntime
                        .records[childID],
                      let groupID = child.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID],
                      let owner = interpreter.concurrencyRuntime
                        .records[group.ownerTaskID] else {
                    throw RuntimeError(message:
                        "owner-cancelled task-group defer cleanup lost runtime ownership")
                }
                observedChild = child
                observedGroup = group
                observedOwner = owner
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        var ownerDeferEvents: [String] = []
        @MainActor
        var ownerDeferChildStarted = false
        @MainActor
        var ownerDeferReady = false
        @MainActor
        var ownerDeferReleaseChild = false
        @MainActor
        func ownerDeferChild() async -> String {
            ownerDeferChildStarted = true
            ownerDeferEvents.append("child-start")
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {}
            while !ownerDeferReleaseChild {
                await Task.yield()
            }
            inspectOwnerCancelledTaskGroupDeferCleanup()
            let state = Task.isCancelled
                ? "child-cancelled"
                : "child-active"
            ownerDeferEvents.append(state)
            return state
        }
        @MainActor
        func ownerDeferBody() async -> String {
            await withTaskGroup(of: String.self) { group in
                group.addTask {
                    await ownerDeferChild()
                }
                while !ownerDeferChildStarted {
                    await Task.yield()
                }
                ownerDeferReady = true
                while !Task.isCancelled {
                    await Task.yield()
                }
                defer {
                    ownerDeferEvents.append("defer")
                    ownerDeferReleaseChild = true
                }
                ownerDeferEvents.append("scope-exit")
            }
            return ownerDeferEvents.joined(separator: ",")
        }
        @MainActor
        func ownerDeferProbe() async -> String {
            let owner = Task {
                await ownerDeferBody()
            }
            while !ownerDeferReady {
                await Task.yield()
            }
            owner.cancel()
            let value = await owner.value
            let state = owner.isCancelled ? "cancelled" : "active"
            return value + ",returned:" + state
        }
        await ownerDeferProbe()
        """)

        #expect(result.stringValue
            == "child-start,scope-exit,defer,child-cancelled,returned:cancelled")
        #expect(observedGroup?.kind == .nonthrowing)
        #expect(observedGroup?.hasOwnerCancellationRequest == true)
        #expect(observedGroup?.hasCancelAllRequest == false)
        #expect(observedGroup?.completedChildTaskIDs.count == 1)
        #expect(observedGroup?.consumedChildTaskIDs.isEmpty == true)
        #expect(observedGroup?.pendingCompletedChildCount == 1)
        #expect(observedChild?.kind == .groupChild)
        #expect(observedChild?.state == .succeeded)
        #expect(observedChild?.cancellation.sources == [.structuredParent])
        #expect(observedChild?.cancellation.isObserved == true)
        #expect(observedOwner?.state == .succeeded)
        #expect(observedOwner?.cancellation.sources == [.taskHandle])
        #expect(observedOwner?.cancellation.isObserved == true)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupKeepsDistinctRuntimeKind() async throws {
        let interpreter = Interpreter()
        var observedKind: RuntimeTaskGroupKind?
        interpreter.globals.define(
            "inspectThrowingTaskGroupChild",
            .hostFunction(HostFunction(
                name: "inspectThrowingTaskGroupChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let groupID = child.taskGroupID,
                          let group = interpreter.concurrencyRuntime
                            .taskGroups[groupID] else {
                        throw RuntimeError(message:
                            "throwing task-group child lost runtime ownership")
                    }
                    observedKind = group.kind
                    return .native("value")
                })))

        let result = try await interpreter.runAsync(source: """
        func inspectedThrowingTaskGroupChild() async -> String {
            await inspectThrowingTaskGroupChild()
        }
        func inspectedThrowingTaskGroupOwner() async throws -> String {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    await inspectedThrowingTaskGroupChild()
                }
                return try await group.next() ?? "empty"
            }
        }
        try await inspectedThrowingTaskGroupOwner()
        """)

        #expect(result.stringValue == "value")
        #expect(observedKind == .throwing)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupNextRethrowsSourceFailure() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        enum ThrowingGroupChildError: Error {
            case failed
        }
        func throwingGroupFailureOwner() async -> String {
            do {
                return try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask {
                        throw ThrowingGroupChildError.failed
                    }
                    _ = try await group.next()
                    return "missed"
                }
            } catch {
                switch error {
                case ThrowingGroupChildError.failed:
                    return "caught-child"
                default:
                    return "wrong-error"
                }
            }
        }
        await throwingGroupFailureOwner()
        """)

        #expect(result.stringValue == "caught-child")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupNextProjectsChildCancellation() async throws {
        let interpreter = Interpreter()
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?
        interpreter.globals.define(
            "observeThrowingNextCancellation",
            .hostFunction(HostFunction(
                name: "observeThrowingNextCancellation"
            ) { _, _ in
                guard let group = interpreter.concurrencyRuntime
                        .taskGroups.values.first,
                      let owner = interpreter.concurrencyRuntime
                        .records[group.ownerTaskID] else {
                    throw RuntimeError(message:
                        "throwing next cancellation lost runtime ownership")
                }
                observedGroup = group
                observedOwner = owner
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        func throwingNextCancellationOwner() async -> String {
            do {
                _ = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.cancelAll()
                    group.addTask {
                        observeThrowingNextCancellation()
                        try Task.checkCancellation()
                        return "missed"
                    }
                    _ = try await group.next()
                    return "missed"
                }
                return "missed"
            } catch {
                let errorKind = type(of: error) == CancellationError.self
                    ? "cancellation"
                    : "wrong-error"
                let ownerState = Task.isCancelled
                    ? "owner-cancelled"
                    : "owner-active"
                return errorKind + ":" + ownerState
            }
        }
        await throwingNextCancellationOwner()
        """)

        #expect(result.stringValue == "cancellation:owner-active")
        #expect(observedGroup?.completedChildTaskIDs.count == 1)
        #expect(observedGroup?.consumedChildTaskIDs.count == 1)
        #expect(observedGroup?.pendingCompletedChildCount == 0)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func multipleThrowingWaitFailuresUseCompletionOrder() async throws {
        let interpreter = Interpreter()
        var firstFailureGateOpen = false
        var firstFailureGateStarted = false
        var observedGroup: RuntimeTaskGroupRecord?
        interpreter.globals.define(
            "waitForOrderedFirstFailure",
            .hostFunction(HostFunction(
                name: "waitForOrderedFirstFailure",
                asyncInvoke: { _, _ in
                    firstFailureGateStarted = true
                    while !firstFailureGateOpen { await Task.yield() }
                    return .void
                })))

        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: """
            enum OrderedThrowingWaitFailure: Error {
                case first
                case second
            }
            func orderedThrowingWaitOwner() async -> String {
                do {
                    _ = try await withThrowingTaskGroup(
                        of: String.self
                    ) { group in
                        group.addTask {
                            await waitForOrderedFirstFailure()
                            throw OrderedThrowingWaitFailure.first
                        }
                        group.addTask {
                            throw OrderedThrowingWaitFailure.second
                        }
                        try await group.waitForAll()
                        return "missed"
                    }
                    return "missed"
                } catch {
                    switch error {
                    case OrderedThrowingWaitFailure.first:
                        return "caught-first"
                    case OrderedThrowingWaitFailure.second:
                        return "caught-second"
                    default:
                        return "wrong-error"
                    }
                }
            }
            await orderedThrowingWaitOwner()
            """)
        }

        for _ in 0..<10_000 {
            if firstFailureGateStarted,
               let group = interpreter.concurrencyRuntime.taskGroups.values.first,
               group.completedChildTaskIDs.count == 1 {
                observedGroup = group
                break
            }
            await Task.yield()
        }
        #expect(observedGroup != nil)
        firstFailureGateOpen = true

        let result = try await evaluation.value
        #expect(result.stringValue == "caught-second")
        #expect(observedGroup?.completedChildTaskIDs.count == 2)
        #expect(observedGroup?.consumedChildTaskIDs.count == 2)
        #expect(observedGroup?.pendingCompletedChildCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func singleFailureAmongThrowingGroupOutcomesRethrows() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        enum SingleThrowingWaitFailure: Error {
            case failed
        }
        func singleFailureThrowingWaitOwner() async -> String {
            do {
                _ = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask { "first" }
                    group.addTask { "second" }
                    group.addTask {
                        throw SingleThrowingWaitFailure.failed
                    }
                    try await group.waitForAll()
                    return "missed"
                }
                return "missed"
            } catch {
                switch error {
                case SingleThrowingWaitFailure.failed:
                    return "caught-child"
                default:
                    return "wrong-error"
                }
            }
        }
        await singleFailureThrowingWaitOwner()
        """)

        #expect(result.stringValue == "caught-child")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingWaitCancellationRethrowsWithoutCancellingOwner() async throws {
        let interpreter = Interpreter()
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?
        interpreter.globals.define(
            "observeThrowingWaitCancellation",
            .hostFunction(HostFunction(
                name: "observeThrowingWaitCancellation"
            ) { _, _ in
                guard let group = interpreter.concurrencyRuntime
                        .taskGroups.values.first,
                      let owner = interpreter.concurrencyRuntime
                        .records[group.ownerTaskID] else {
                    throw RuntimeError(message:
                        "throwing wait cancellation lost runtime ownership")
                }
                observedGroup = group
                observedOwner = owner
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        var throwingWaitCancellationCompletions = 0
        @MainActor
        func recordThrowingWaitCancellationCompletion() {
            throwingWaitCancellationCompletions += 1
            observeThrowingWaitCancellation()
        }
        @MainActor
        func cancelledThrowingWaitOwner() async -> String {
            do {
                _ = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.cancelAll()
                    group.addTask {
                        await recordThrowingWaitCancellationCompletion()
                        try Task.checkCancellation()
                        return "missed"
                    }
                    group.addTask {
                        await recordThrowingWaitCancellationCompletion()
                        return "success"
                    }
                    try await group.waitForAll()
                    return "missed"
                }
                return "missed"
            } catch {
                let errorKind = type(of: error) == CancellationError.self
                    ? "cancellation"
                    : "wrong-error"
                let ownerState = Task.isCancelled
                    ? "owner-cancelled"
                    : "owner-active"
                let drained = throwingWaitCancellationCompletions == 2
                    ? "drained"
                    : "not-drained"
                return errorKind + ":" + ownerState + ":" + drained
            }
        }
        await cancelledThrowingWaitOwner()
        """)

        #expect(result.stringValue == "cancellation:owner-active:drained")
        #expect(observedGroup?.completedChildTaskIDs.count == 2)
        #expect(observedGroup?.consumedChildTaskIDs.count == 2)
        #expect(observedGroup?.pendingCompletedChildCount == 0)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func multipleSuccessfulThrowingGroupWaitCleansUp() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        func multipleSuccessfulThrowingWaitOwner() async -> String {
            do {
                return try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask { "first" }
                    group.addTask { "second" }
                    group.addTask { "third" }
                    try await group.waitForAll()
                    return "all-success"
                }
            } catch {
                return "error"
            }
        }
        await multipleSuccessfulThrowingWaitOwner()
        """)

        #expect(result.stringValue == "all-success")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func emptyThrowingTaskGroupWaitCompletesAndCleansUp() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        func emptyThrowingWaitOwner() async -> String {
            do {
                return try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    try await group.waitForAll()
                    return "empty"
                }
            } catch {
                return "error"
            }
        }
        await emptyThrowingWaitOwner()
        """)

        #expect(result.stringValue == "empty")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupExplicitWaitAndImplicitExitDiffer() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        enum ThrowingWaitChildError: Error {
            case failed
        }
        func throwingWaitOwner() async -> String {
            do {
                let success = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask {
                        return "value"
                    }
                    try await group.waitForAll()
                    return "success"
                }
                do {
                    _ = try await withThrowingTaskGroup(
                        of: String.self
                    ) { group in
                        group.addTask {
                            throw ThrowingWaitChildError.failed
                        }
                        try await group.waitForAll()
                        return "missed"
                    }
                    return success + ":missed"
                } catch {
                    switch error {
                    case ThrowingWaitChildError.failed:
                        return success + ":caught-child"
                    default:
                        return success + ":wrong-error"
                    }
                }
            } catch {
                return "wrong-success"
            }
        }
        await throwingWaitOwner()
        """)

        #expect(result.stringValue == "success:caught-child")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)

        let implicitResult = try await interpreter.runAsync(source: """
            enum UnconsumedThrowingGroupError: Error {
                case failed
            }
            @MainActor
            var unconsumedThrowingGroupCompletions = 0
            @MainActor
            func recordUnconsumedThrowingGroupCompletion() {
                unconsumedThrowingGroupCompletions += 1
            }
            func unconsumedThrowingGroupOwner() async -> String {
                let value = await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask {
                        await recordUnconsumedThrowingGroupCompletion()
                        return "first"
                    }
                    group.addTask {
                        await recordUnconsumedThrowingGroupCompletion()
                        throw UnconsumedThrowingGroupError.failed
                    }
                    group.addTask {
                        await recordUnconsumedThrowingGroupCompletion()
                        return "third"
                    }
                    return "body"
                }
                if unconsumedThrowingGroupCompletions == 3 {
                    return value + ":joined"
                }
                return value + ":not-joined"
            }
            await unconsumedThrowingGroupOwner()
            """)

        #expect(implicitResult.stringValue == "body:joined")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupBodyThrowCancelsAndJoinsChild() async throws {
        let interpreter = Interpreter()
        var observedChild: RuntimeTaskRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?
        interpreter.globals.define(
            "inspectThrowingBodyChildCancellation",
            .hostFunction(HostFunction(
                name: "inspectThrowingBodyChildCancellation",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let groupID = child.taskGroupID,
                          let group = interpreter.concurrencyRuntime
                            .taskGroups[groupID],
                          let owner = interpreter.concurrencyRuntime
                            .records[group.ownerTaskID] else {
                        throw RuntimeError(message:
                            "throwing body cleanup lost runtime ownership")
                    }
                    observedChild = child
                    observedGroup = group
                    observedOwner = owner
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        enum ThrowingBodyError: Error {
            case failed
        }
        @MainActor
        var throwingBodyEvents: [String] = []
        @MainActor
        var throwingBodyChildStarted = false
        @MainActor
        func throwingBodyChild() async -> String {
            throwingBodyChildStarted = true
            throwingBodyEvents.append("child-start")
            do {
                try await Task.sleep(for: .seconds(30))
                return "missed"
            } catch {
                await inspectThrowingBodyChildCancellation()
                throwingBodyEvents.append("child-cancelled")
                return "cancelled"
            }
        }
        @MainActor
        func throwingBodyOwner() async -> String {
            do {
                _ = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask {
                        await throwingBodyChild()
                    }
                    while !throwingBodyChildStarted {
                        await Task.yield()
                    }
                    throwingBodyEvents.append("body-throw")
                    throw ThrowingBodyError.failed
                }
                throwingBodyEvents.append("missed")
            } catch ThrowingBodyError.failed {
                throwingBodyEvents.append("caught-body")
            } catch {
                throwingBodyEvents.append("wrong-error")
            }
            return throwingBodyEvents.joined(separator: ",")
        }
        await throwingBodyOwner()
        """)

        #expect(result.stringValue
            == "child-start,body-throw,child-cancelled,caught-body")
        #expect(observedGroup?.kind == .throwing)
        #expect(observedGroup?.completedChildTaskIDs.count == 1)
        #expect(observedGroup?.consumedChildTaskIDs.isEmpty == true)
        #expect(observedGroup?.pendingCompletedChildCount == 1)
        #expect(observedChild?.kind == .groupChild)
        #expect(observedChild?.state == .succeeded)
        #expect(observedChild?.cancellation.sources == [.structuredScopeExit])
        #expect(observedChild?.cancellation.isObserved == true)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupIterationFailureCancelsSibling() async throws {
        let interpreter = Interpreter()
        var observedFailure: RuntimeTaskRecord?
        var observedSibling: RuntimeTaskRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?
        interpreter.globals.define(
            "inspectThrowingIterationFailure",
            .hostFunction(HostFunction(
                name: "inspectThrowingIterationFailure",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID] else {
                        throw RuntimeError(message:
                            "throwing iteration failure lost its runtime task")
                    }
                    observedFailure = child
                    return .void
                })))
        interpreter.globals.define(
            "inspectThrowingIterationSiblingCancellation",
            .hostFunction(HostFunction(
                name: "inspectThrowingIterationSiblingCancellation",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let groupID = child.taskGroupID,
                          let group = interpreter.concurrencyRuntime
                            .taskGroups[groupID],
                          let owner = interpreter.concurrencyRuntime
                            .records[group.ownerTaskID] else {
                        throw RuntimeError(message:
                            "throwing iteration cleanup lost runtime ownership")
                    }
                    observedSibling = child
                    observedGroup = group
                    observedOwner = owner
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        enum ThrowingIterationError: Error {
            case failed
        }
        @MainActor
        var throwingIterationEvents: [String] = []
        @MainActor
        var throwingIterationSiblingStarted = false
        @MainActor
        func throwingIterationSibling() async -> Int {
            throwingIterationSiblingStarted = true
            throwingIterationEvents.append("sibling-start")
            do {
                try await Task.sleep(for: .seconds(30))
                return 1
            } catch {
                await inspectThrowingIterationSiblingCancellation()
                throwingIterationEvents.append("sibling-cancelled")
                return 2
            }
        }
        @MainActor
        func throwingIterationFailure() async throws -> Int {
            while !throwingIterationSiblingStarted {
                await Task.yield()
            }
            await inspectThrowingIterationFailure()
            throwingIterationEvents.append("child-failed")
            throw ThrowingIterationError.failed
        }
        @MainActor
        func throwingIterationOwner() async -> String {
            do {
                _ = try await withThrowingTaskGroup(
                    of: Int.self
                ) { group in
                    group.addTask {
                        await throwingIterationSibling()
                    }
                    group.addTask {
                        try await throwingIterationFailure()
                    }
                    for try await _ in group {
                        throwingIterationEvents.append("unexpected-value")
                    }
                    return "missed"
                }
                throwingIterationEvents.append("missed")
            } catch ThrowingIterationError.failed {
                throwingIterationEvents.append("caught-child")
            } catch {
                throwingIterationEvents.append("wrong-error")
            }
            return throwingIterationEvents.joined(separator: ",")
        }
        await throwingIterationOwner()
        """)

        #expect(result.stringValue
            == "sibling-start,child-failed,sibling-cancelled,caught-child")
        #expect(observedGroup?.kind == .throwing)
        #expect(observedGroup?.completedChildTaskIDs.count == 2)
        #expect(observedGroup?.consumedChildTaskIDs.count == 1)
        #expect(observedGroup?.pendingCompletedChildCount == 1)
        #expect(observedFailure?.kind == .groupChild)
        #expect(observedFailure?.state == .failed)
        #expect(observedFailure?.cancellation.isRequested == false)
        #expect(observedFailure.map {
            observedGroup?.consumedChildTaskIDs.contains($0.id) == true
        } == true)
        #expect(observedSibling?.kind == .groupChild)
        #expect(observedSibling?.state == .succeeded)
        #expect(observedSibling?.cancellation.sources == [.structuredScopeExit])
        #expect(observedSibling?.cancellation.isObserved == true)
        #expect(observedSibling.map {
            observedGroup?.consumedChildTaskIDs.contains($0.id) == false
        } == true)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupIterationProjectsCancellation() async throws {
        let interpreter = Interpreter()
        var observedCancelledChild: RuntimeTaskRecord?
        var observedSibling: RuntimeTaskRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?

        func observeCurrentChild(
            assigning child: inout RuntimeTaskRecord?
        ) throws {
            guard let childID = interpreter.evaluationTaskContext.runtimeTaskID,
                  let current = interpreter.concurrencyRuntime.records[childID],
                  let groupID = current.taskGroupID,
                  let group = interpreter.concurrencyRuntime.taskGroups[groupID],
                  let owner = interpreter.concurrencyRuntime
                    .records[group.ownerTaskID] else {
                throw RuntimeError(message:
                    "throwing iteration cancellation lost runtime ownership")
            }
            child = current
            observedGroup = group
            observedOwner = owner
        }

        interpreter.globals.define(
            "inspectThrowingIterationCancelledChild",
            .hostFunction(HostFunction(
                name: "inspectThrowingIterationCancelledChild"
            ) { _, _ in
                try observeCurrentChild(assigning: &observedCancelledChild)
                return .void
            }))
        interpreter.globals.define(
            "inspectThrowingIterationCancelledSibling",
            .hostFunction(HostFunction(
                name: "inspectThrowingIterationCancelledSibling"
            ) { _, _ in
                try observeCurrentChild(assigning: &observedSibling)
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        var throwingIterationCancellationCompletions = 0
        @MainActor
        var throwingIterationCancellationSiblingStarted = false
        @MainActor
        func throwingIterationCancellationSibling() async -> String {
            throwingIterationCancellationSiblingStarted = true
            do {
                try await Task.sleep(for: .seconds(30))
                return "missed"
            } catch {
                inspectThrowingIterationCancelledSibling()
                throwingIterationCancellationCompletions += 1
                return "sibling"
            }
        }
        @MainActor
        func throwingIterationCancelledChild() async throws -> String {
            inspectThrowingIterationCancelledChild()
            throwingIterationCancellationCompletions += 1
            try Task.checkCancellation()
            return "missed"
        }
        @MainActor
        func throwingIterationCancellationOwner() async -> String {
            do {
                _ = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask {
                        await throwingIterationCancellationSibling()
                    }
                    while !throwingIterationCancellationSiblingStarted {
                        await Task.yield()
                    }
                    group.cancelAll()
                    group.addTask {
                        try await throwingIterationCancelledChild()
                    }
                    for try await _ in group {}
                    return "missed"
                }
                return "missed"
            } catch {
                let kind = type(of: error) == CancellationError.self
                    ? "cancellation"
                    : "wrong-error"
                let owner = Task.isCancelled
                    ? "owner-cancelled"
                    : "owner-active"
                let joined = throwingIterationCancellationCompletions == 2
                    ? "joined"
                    : "not-joined"
                return kind + ":" + owner + ":" + joined
            }
        }
        await throwingIterationCancellationOwner()
        """)

        let consumedCount = observedGroup?.consumedChildTaskIDs.count ?? 0
        #expect(result.stringValue == "cancellation:owner-active:joined")
        #expect(observedGroup?.kind == .throwing)
        #expect(observedGroup?.hasCancelAllRequest == true)
        #expect(observedGroup?.completedChildTaskIDs.count == 2)
        #expect((1...2).contains(consumedCount))
        #expect(observedGroup?.pendingCompletedChildCount == 2 - consumedCount)
        #expect(observedCancelledChild?.kind == .groupChild)
        #expect(observedCancelledChild?.state == .cancelled)
        #expect(observedCancelledChild?.cancellation.sources
            .contains(.taskGroupCancelAll) == true)
        #expect(observedCancelledChild?.cancellation.isObserved == true)
        #expect(observedCancelledChild.map {
            observedGroup?.consumedChildTaskIDs.contains($0.id) == true
        } == true)
        #expect(observedSibling?.kind == .groupChild)
        #expect(observedSibling?.state == .succeeded)
        #expect(observedSibling?.cancellation.sources
            .contains(.taskGroupCancelAll) == true)
        #expect(observedSibling?.cancellation.isObserved == true)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupIterationBreakJoinsWithoutCancellation()
    async throws {
        let interpreter = Interpreter()
        var observedFirst: RuntimeTaskRecord?
        var observedSibling: RuntimeTaskRecord?
        var observedGroup: RuntimeTaskGroupRecord?
        var observedOwner: RuntimeTaskRecord?

        func observeCurrentChild(
            assigning child: inout RuntimeTaskRecord?
        ) throws {
            guard let childID = interpreter.evaluationTaskContext.runtimeTaskID,
                  let current = interpreter.concurrencyRuntime.records[childID],
                  let groupID = current.taskGroupID,
                  let group = interpreter.concurrencyRuntime.taskGroups[groupID],
                  let owner = interpreter.concurrencyRuntime
                    .records[group.ownerTaskID] else {
                throw RuntimeError(message:
                    "throwing iteration early exit lost runtime ownership")
            }
            child = current
            observedGroup = group
            observedOwner = owner
        }

        interpreter.globals.define(
            "inspectThrowingIterationEarlyExitFirst",
            .hostFunction(HostFunction(
                name: "inspectThrowingIterationEarlyExitFirst"
            ) { _, _ in
                try observeCurrentChild(assigning: &observedFirst)
                return .void
            }))
        interpreter.globals.define(
            "inspectThrowingIterationEarlyExitSibling",
            .hostFunction(HostFunction(
                name: "inspectThrowingIterationEarlyExitSibling"
            ) { _, _ in
                try observeCurrentChild(assigning: &observedSibling)
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        var throwingIterationEarlyExitSiblingStarted = false
        @MainActor
        var throwingIterationEarlyExitReleaseSibling = false
        @MainActor
        var throwingIterationEarlyExitSiblingState = "missing"
        @MainActor
        var throwingIterationEarlyExitCompletions = 0
        @MainActor
        func throwingIterationEarlyExitSibling() async -> String {
            throwingIterationEarlyExitSiblingStarted = true
            while !throwingIterationEarlyExitReleaseSibling {
                await Task.yield()
            }
            inspectThrowingIterationEarlyExitSibling()
            throwingIterationEarlyExitSiblingState = Task.isCancelled
                ? "cancelled"
                : "active"
            throwingIterationEarlyExitCompletions += 1
            return "sibling"
        }
        @MainActor
        func throwingIterationEarlyExitFirst() async -> String {
            while !throwingIterationEarlyExitSiblingStarted {
                await Task.yield()
            }
            inspectThrowingIterationEarlyExitFirst()
            throwingIterationEarlyExitCompletions += 1
            return "first"
        }
        @MainActor
        func throwingIterationEarlyExitOwner() async -> String {
            do {
                let first = try await withThrowingTaskGroup(
                    of: String.self
                ) { group in
                    group.addTask {
                        await throwingIterationEarlyExitSibling()
                    }
                    group.addTask {
                        await throwingIterationEarlyExitFirst()
                    }
                    var observed = "none"
                    for try await value in group {
                        observed = value
                        throwingIterationEarlyExitReleaseSibling = true
                        break
                    }
                    return observed
                }
                let owner = Task.isCancelled
                    ? "owner-cancelled"
                    : "owner-active"
                let joined = throwingIterationEarlyExitCompletions == 2
                    ? "joined"
                    : "not-joined"
                return first + ":" + throwingIterationEarlyExitSiblingState
                    + ":" + owner + ":" + joined
            } catch {
                throwingIterationEarlyExitReleaseSibling = true
                return "error"
            }
        }
        await throwingIterationEarlyExitOwner()
        """)

        #expect(result.stringValue == "first:active:owner-active:joined")
        #expect(observedGroup?.kind == .throwing)
        #expect(observedGroup?.hasCancelAllRequest == false)
        #expect(observedGroup?.completedChildTaskIDs.count == 2)
        #expect(observedGroup?.consumedChildTaskIDs.count == 1)
        #expect(observedGroup?.pendingCompletedChildCount == 1)
        #expect(observedFirst?.kind == .groupChild)
        #expect(observedFirst?.state == .succeeded)
        #expect(observedFirst?.cancellation.isRequested == false)
        #expect(observedFirst.map {
            observedGroup?.consumedChildTaskIDs.contains($0.id) == true
        } == true)
        #expect(observedSibling?.kind == .groupChild)
        #expect(observedSibling?.state == .succeeded)
        #expect(observedSibling?.cancellation.isRequested == false)
        #expect(observedSibling.map {
            observedGroup?.consumedChildTaskIDs.contains($0.id) == false
        } == true)
        #expect(observedOwner?.cancellation.isRequested == false)
        #expect(observedOwner?.cancellation.isObserved == false)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskGroupNextUsesCompletionQueueAndGroupSuspension() async throws {
        let interpreter = Interpreter()
        var observedParentSuspension: RuntimeSuspension?
        var observedGroupID: RuntimeTaskGroupID?
        var observedConsumedResult = false
        interpreter.globals.define(
            "inspectTaskGroupNextChild",
            .hostFunction(HostFunction(
                name: "inspectTaskGroupNextChild",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let childID = bound.evaluationContext.runtimeTaskID,
                          let child = interpreter.concurrencyRuntime
                            .records[childID],
                          let parentID = child.parent,
                          let parent = interpreter.concurrencyRuntime
                            .records[parentID],
                          let group = interpreter.concurrencyRuntime
                            .taskGroups.values.first(where: {
                                $0.childTaskIDs.contains(childID)
                            }) else {
                        throw RuntimeError(message:
                            "task-group next child lost runtime ownership")
                    }

                    for _ in 0..<1_000 {
                        if case .waitingForGroup(let groupID)? =
                            parent.suspension,
                           groupID == group.id {
                            observedParentSuspension = parent.suspension
                            observedGroupID = group.id
                            return .native("value")
                        }
                        await Task.yield()
                    }
                    throw RuntimeError(message:
                        "task-group next owner did not suspend")
                })))
        interpreter.globals.define(
            "inspectTaskGroupNextConsumption",
            .hostFunction(HostFunction(
                name: "inspectTaskGroupNextConsumption"
            ) { _, _ in
                guard let observedGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[observedGroupID] else {
                    throw RuntimeError(message:
                        "task-group next owner lost its active group")
                }
                observedConsumedResult = group.pendingCompletedChildCount == 0
                    && group.consumedChildTaskIDs.count == 1
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        func inspectedTaskGroupNextChild() async -> String {
            await inspectTaskGroupNextChild()
        }
        func inspectedTaskGroupNextOwner() async -> String {
            await withTaskGroup(of: String.self) { group in
                group.addTask {
                    await inspectedTaskGroupNextChild()
                }
                let value = await group.next() ?? "missing"
                inspectTaskGroupNextConsumption()
                return value
            }
        }
        await inspectedTaskGroupNextOwner()
        """)

        #expect(result.stringValue == "value")
        if case .waitingForGroup = observedParentSuspension {
            // `next()` waits on the logical structured group.
        } else {
            Issue.record("task-group next did not record group suspension")
        }
        #expect(observedConsumedResult)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskGroupForAwaitStreamsAndConsumesEveryResult() async throws {
        let interpreter = Interpreter()
        var observedSingleConsumedResult = false
        interpreter.globals.define(
            "inspectTaskGroupIteration",
            .hostFunction(HostFunction(
                name: "inspectTaskGroupIteration"
            ) { _, _ in
                guard let group = interpreter.concurrencyRuntime
                    .taskGroups.values.first else {
                    throw RuntimeError(message:
                        "task-group iteration lost its active group")
                }
                observedSingleConsumedResult =
                    group.consumedChildTaskIDs.count == 1
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        await withTaskGroup(of: Int.self) { group in
            group.addTask { 1 }
            group.addTask { 2 }
            group.addTask { 3 }

            var count = 0
            var total = 0
            for await value in group {
                if count == 0 {
                    inspectTaskGroupIteration()
                }
                count += 1
                total += value
            }

            let tail = await group.next() ?? 0
            return "\\(count):\\(total):\\(tail)"
        }
        """)

        #expect(result.stringValue == "3:6:0")
        #expect(observedSingleConsumedResult)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingTaskGroupForAwaitUsesSharedCompletionQueue() async throws {
        let interpreter = Interpreter()
        var observedConsumptionCounts: [Int] = []
        var observedDrainedGroup = false
        interpreter.globals.define(
            "inspectThrowingTaskGroupIteration",
            .hostFunction(HostFunction(
                name: "inspectThrowingTaskGroupIteration"
            ) { _, _ in
                guard let group = interpreter.concurrencyRuntime
                    .taskGroups.values.first,
                      group.kind == .throwing else {
                    throw RuntimeError(message:
                        "throwing task-group iteration lost its active group")
                }
                observedConsumptionCounts.append(
                    group.consumedChildTaskIDs.count)
                return .void
            }))
        interpreter.globals.define(
            "inspectThrowingTaskGroupIterationDone",
            .hostFunction(HostFunction(
                name: "inspectThrowingTaskGroupIterationDone"
            ) { _, _ in
                guard let group = interpreter.concurrencyRuntime
                    .taskGroups.values.first else {
                    throw RuntimeError(message:
                        "throwing task-group iteration lost its drained group")
                }
                observedDrainedGroup = group.childTaskIDs.count == 3
                    && group.completedChildTaskIDs.count == 3
                    && group.consumedChildTaskIDs.count == 3
                    && group.pendingCompletedChildCount == 0
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        do {
            return try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask { 1 }
                group.addTask { 2 }
                group.addTask { 3 }

                var count = 0
                var total = 0
                for try await value in group {
                    count += 1
                    total += value
                    inspectThrowingTaskGroupIteration()
                }
                let tail = try await group.next() ?? 0
                inspectThrowingTaskGroupIterationDone()
                return String(count) + ":" + String(total) + ":" + String(tail)
            }
        } catch {
            return "error"
        }
        """)

        #expect(result.stringValue == "3:6:0")
        #expect(observedConsumptionCounts == [1, 2, 3])
        #expect(observedDrainedGroup)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func taskGroupWaitForAllConsumesPendingResults() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        await withTaskGroup(of: String.self) { group in
            group.addTask {
                return "value"
            }
            await group.waitForAll()
            return await group.next() ?? "empty"
        }
        """)

        #expect(result.stringValue == "empty")
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func cancelledEvaluationThrowsCancellationError() async {
        let interpreter = Interpreter()
        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: "while true { _ = 1 + 1 }")
        }
        evaluation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await evaluation.value
        }
    }

    @Test func hostSessionAbortBypassesSourceCatchAndUsesOnlyHostSource()
        async throws {
        let interpreter = Interpreter()
        let state = HostSessionAbortProbeState()
        interpreter.globals.define(
            "waitForHostSessionAbort",
            .hostFunction(HostFunction(
                name: "waitForHostSessionAbort",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let taskID = bound.evaluationContext.runtimeTaskID,
                          let record = interpreter.concurrencyRuntime
                            .records[taskID] else {
                        throw RuntimeError(message:
                            "host abort requires a runtime root task")
                    }
                    state.rootRecord = record
                    state.started = true
                    try await Task.sleep(for: .seconds(30))
                    return .void
                })))
        interpreter.globals.define(
            "recordHostSessionAbortSourceCatch",
            .hostFunction(HostFunction(
                name: "recordHostSessionAbortSourceCatch",
                invoke: { _, _ in
                    state.sourceCatchCount += 1
                    return .void
                })))

        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: """
            do {
                try await waitForHostSessionAbort()
            } catch is CancellationError {
                recordHostSessionAbortSourceCatch()
            }
            "completed"
            """)
        }
        while !state.started { await Task.yield() }
        evaluation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await evaluation.value
        }
        let record = try #require(state.rootRecord)
        #expect(state.sourceCatchCount == 0)
        #expect(record.kind == .root)
        #expect(record.state == .cancelled)
        if case .cancelled? = record.outcome {
            // Expected infrastructure outcome.
        } else {
            Issue.record("expected a cancelled root outcome")
        }
        #expect(record.cancellation.sources == [.hostTask])
        #expect(record.cancellation.isObserved)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func hostSessionAbortBypassesOptionalTry() async throws {
        let interpreter = Interpreter()
        let state = HostSessionAbortProbeState()
        interpreter.globals.define(
            "waitForHostSessionAbort",
            .hostFunction(HostFunction(
                name: "waitForHostSessionAbort",
                asyncInvoke: { _, context in
                    guard let bound = context as? TaskBoundEvalContext,
                          let taskID = bound.evaluationContext.runtimeTaskID,
                          let record = interpreter.concurrencyRuntime
                            .records[taskID] else {
                        throw RuntimeError(message:
                            "host abort requires a runtime root task")
                    }
                    state.rootRecord = record
                    state.started = true
                    try await Task.sleep(for: .seconds(30))
                    return .void
                })))

        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: """
            try? await waitForHostSessionAbort()
            "completed"
            """)
        }
        while !state.started { await Task.yield() }
        evaluation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await evaluation.value
        }
        let record = try #require(state.rootRecord)
        #expect(record.state == .cancelled)
        #expect(record.cancellation.sources == [.hostTask])
        #expect(record.cancellation.isObserved)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func asyncHostGatewaySuspendsThroughInterpretedFunction() async throws {
        let interpreter = Interpreter()
        var events: [String] = []
        interpreter.globals.define("record", .hostFunction(HostFunction(
            name: "record"
        ) { arguments, _ in
            events.append(arguments.positional(0)?.stringValue ?? "?")
            return .void
        }))
        interpreter.globals.define("delayedText", .hostFunction(HostFunction(
            name: "delayedText",
            asyncInvoke: { arguments, _ in
                events.append("host-enter")
                await Task.yield()
                events.append("host-exit")
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let result = try await interpreter.runAsync(source: """
        func load() async -> String {
            record("before")
            let value: String = await delayedText("value")
            record("after")
            return value + "!"
        }
        await load()
        """)

        #expect(result.stringValue == "value!")
        #expect(events == ["before", "host-enter", "host-exit", "after"])
    }

    @Test func interpretedTaskBodyCanAwaitAsyncHostGateway() async throws {
        let interpreter = Interpreter()
        interpreter.globals.define("delayedText", .hostFunction(HostFunction(
            name: "delayedText",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let state = try await interpreter.runAsync(source: """
        class State { var value = "pending" }
        let state = State()
        Task {
            state.value = await delayedText("finished")
        }
        state
        """)

        guard case .instance(let instance) = state else {
            Issue.record("expected an interpreted State")
            return
        }
        #expect(instance.box(for: "value")?.value.stringValue == "finished")
    }

    @Test func interleavedTasksKeepIndependentLexicalFrames() async throws {
        let interpreter = Interpreter()
        interpreter.globals.define("yielding", .hostFunction(HostFunction(
            name: "yielding",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let state = try await interpreter.runAsync(source: """
        class State { var values = [String]() }
        struct Alpha {
            enum Token: String { case value = "alpha" }
            func run() async -> String {
                (await yielding("")) + Token.value.rawValue
            }
        }
        struct Beta {
            enum Token: String { case value = "beta" }
            func run() async -> String {
                (await yielding("")) + Token.value.rawValue
            }
        }
        let state = State()
        Task {
            let value = await Alpha().run()
            state.values.append(value)
        }
        Task {
            let value = await Beta().run()
            state.values.append(value)
        }
        state
        """)

        let values = try stringArray(named: "values", in: state)
        #expect(
            values.sorted() == ["alpha", "beta"],
            "task completion order is unspecified; actual values: \(values)"
        )
    }

    @Test func asyncGatewayCanReenterSuspendingInterpretedClosure() async throws {
        let interpreter = Interpreter()
        let state = HostReentrySuspensionState()
        interpreter.globals.define("delayedText", .hostFunction(HostFunction(
            name: "delayedText",
            asyncInvoke: { arguments, _ in
                guard let root = state.rootRecord,
                      let outerOperationID = state.outerOperationID,
                      case .awaitingHost(let nestedOperationID) = root.suspension
                else {
                    throw RuntimeError(message:
                        "nested host gateway requires a suspended root task")
                }
                state.nestedOperationID = nestedOperationID
                state.nestedState = root.state
                state.nestedHostOperationCount = interpreter
                    .concurrencyRuntime.activeHostOperationCount
                state.nestedOuterTaskID = interpreter.concurrencyRuntime
                    .hostOperations[outerOperationID]
                state.nestedOperationTaskID = interpreter.concurrencyRuntime
                    .hostOperations[nestedOperationID]
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))
        interpreter.globals.define(
            "observeHostReentry",
            .hostFunction(HostFunction(
                name: "observeHostReentry",
                invoke: { _, _ in
                    guard let root = state.rootRecord,
                          let outerOperationID = state.outerOperationID else {
                        throw RuntimeError(message:
                            "host callback requires an outer host operation")
                    }
                    state.callbackState = root.state
                    state.callbackSuspension = root.suspension
                    state.callbackHostOperationCount = interpreter
                        .concurrencyRuntime.activeHostOperationCount
                    state.callbackOuterTaskID = interpreter
                        .concurrencyRuntime.hostOperations[outerOperationID]
                    return .void
                })))
        interpreter.globals.define("withValue", .hostFunction(HostFunction(
            name: "withValue",
            asyncInvoke: { arguments, context in
                guard let bound = context as? TaskBoundEvalContext,
                      let taskID = bound.evaluationContext.runtimeTaskID,
                      let root = interpreter.concurrencyRuntime.records[taskID],
                      case .awaitingHost(let operationID) = root.suspension
                else {
                    throw RuntimeError(message:
                        "outer host gateway requires a suspended root task")
                }
                state.rootRecord = root
                state.outerOperationID = operationID
                await Task.yield()
                guard let closure = arguments.firstUnlabeledClosure else {
                    throw ProbeError.failed
                }
                return try await context.callClosureAsync(
                    closure, arguments: [.native("inside")])
            }
        )))

        let result = try await interpreter.runAsync(source: """
        func decorate(_ value: String) async -> String {
            let delayed = await delayedText(value)
            return delayed + "!"
        }
        await withValue { value in
            observeHostReentry()
            await decorate(value)
        }
        """)

        let root = try #require(state.rootRecord)
        let outerOperationID = try #require(state.outerOperationID)
        let nestedOperationID = try #require(state.nestedOperationID)
        #expect(result.stringValue == "inside!")
        #expect(outerOperationID != nestedOperationID)
        #expect(state.callbackState == .running)
        #expect(state.callbackSuspension == nil)
        #expect(state.callbackHostOperationCount == 1)
        #expect(state.callbackOuterTaskID == root.id)
        #expect(state.nestedState == .waiting)
        #expect(state.nestedHostOperationCount == 2)
        #expect(state.nestedOuterTaskID == root.id)
        #expect(state.nestedOperationTaskID == root.id)
        #expect(root.suspensionHistory == [
            .awaitingHost(outerOperationID),
            .awaitingHost(nestedOperationID),
            .awaitingHost(outerOperationID),
        ])
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
    }

    @Test func asyncControlFlowIsLazyAndCatchesHostErrors() async throws {
        let interpreter = Interpreter()
        var calls = 0
        interpreter.globals.define("mark", .hostFunction(HostFunction(
            name: "mark",
            asyncInvoke: { _, _ in
                calls += 1
                await Task.yield()
                return .native(true)
            }
        )))
        interpreter.globals.define("fail", .hostFunction(HostFunction(
            name: "fail",
            asyncInvoke: { _, _ in
                await Task.yield()
                throw ProbeError.failed
            }
        )))

        let result = try await interpreter.runAsync(source: """
        func recovered() async -> String {
            do {
                _ = try await fail()
                return "missed"
            } catch {
                return "caught"
            }
        }
        let andValue = false && (await mark())
        let orValue = true || (await mark())
        let branch = true ? "chosen" : (await mark() ? "wrong" : "also wrong")
        let optional = try? await fail()
        [andValue, orValue, branch, optional == nil, await recovered()]
        """)

        let values = try #require(result.arrayValue)
        #expect(values[0].boolValue == false)
        #expect(values[1].boolValue == true)
        #expect(values[2].stringValue == "chosen")
        #expect(values[3].boolValue == true)
        #expect(values[4].stringValue == "caught")
        #expect(calls == 0)
    }

    @Test func leadingTryAwaitPropagatesThroughLazyTernary() async throws {
        let interpreter = Interpreter()
        var optionalCalls = 0
        var failureCalls = 0
        var untakenCalls = 0
        interpreter.globals.define(
            "conditionalOptional",
            .hostFunction(HostFunction(
                name: "conditionalOptional",
                asyncInvoke: { _, _ in
                    optionalCalls += 1
                    await Task.yield()
                    return .none(wrappedTypeName: "String")
                })))
        interpreter.globals.define(
            "conditionalFailure",
            .hostFunction(HostFunction(
                name: "conditionalFailure",
                asyncInvoke: { _, _ in
                    failureCalls += 1
                    await Task.yield()
                    throw ProbeError.failed
                })))
        interpreter.globals.define(
            "conditionalUntaken",
            .hostFunction(HostFunction(
                name: "conditionalUntaken",
                asyncInvoke: { _, _ in
                    untakenCalls += 1
                    await Task.yield()
                    return .native("wrong")
                })))

        let result = try await interpreter.runAsync(source: """
        func optionalConditional() async -> String {
            do {
                return try await conditionalOptional() == nil
                    ? "nil"
                    : await conditionalUntaken()
            } catch {
                return "error"
            }
        }
        func throwingConditional() async -> String {
            do {
                return try await conditionalFailure() == nil
                    ? "missed"
                    : "also-missed"
            } catch {
                return "caught"
            }
        }
        let optional = await optionalConditional()
        let failure = await throwingConditional()
        optional + ":" + failure
        """)

        #expect(result.stringValue == "nil:caught")
        #expect(optionalCalls == 1)
        #expect(failureCalls == 1)
        #expect(untakenCalls == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func cancellationInterruptsSuspendedHostGateway() async {
        let interpreter = Interpreter()
        var started = false
        interpreter.globals.define("waitForever", .hostFunction(HostFunction(
            name: "waitForever",
            asyncInvoke: { _, _ in
                started = true
                try await Task.sleep(for: .seconds(30))
                return .void
            }
        )))

        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: "await waitForever()")
        }
        while !started { await Task.yield() }
        evaluation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await evaluation.value
        }
    }

    @Test func synchronousEntryRejectsAsyncOnlyGateway() {
        let interpreter = Interpreter()
        interpreter.globals.define("asyncOnly", .hostFunction(HostFunction(
            name: "asyncOnly",
            asyncInvoke: { _, _ in .void }
        )))

        #expect(throws: RuntimeError.self) {
            _ = try interpreter.run(source: "await asyncOnly()")
        }
    }

    @Test func synchronousEntryRejectsAsyncInitializer() {
        let interpreter = Interpreter()

        #expect(throws: RuntimeError.self) {
            _ = try interpreter.run(source: """
            struct DeferredValue {
                init() async {}
            }
            DeferredValue()
            """)
        }
    }

    @Test func taskSleepUsesInjectedClockAndFirstClassSuspension() async throws {
        let clock = ManualRuntimeClock()
        let interpreter = Interpreter(runtimeClock: clock)
        let execution = Task { @MainActor in
            try await interpreter.runAsync(source: """
            let sleeper = Task {
                try await Task.sleep(nanoseconds: 10)
                return "awake"
            }
            await sleeper.value
            """)
        }

        var sleepingRecord: RuntimeTaskRecord?
        for _ in 0..<1_000 {
            sleepingRecord = interpreter.concurrencyRuntime.records.values.first {
                $0.kind == .unstructured && $0.suspension != nil
            }
            if sleepingRecord != nil { break }
            await Task.yield()
        }

        let record = try #require(sleepingRecord)
        #expect(record.state == .waiting)
        #expect(record.suspension == .sleeping(
            until: RuntimeInstant(nanoseconds: 10)))
        #expect(clock.sleepingTaskCount == 1)

        clock.advance(by: .nanoseconds(10))
        let result = try await execution.value
        #expect(result.stringValue == "awake")
        #expect(record.state == .succeeded)
        #expect(record.suspension == nil)
        #expect(record.suspensionHistory == [
            .sleeping(until: RuntimeInstant(nanoseconds: 10)),
        ])
        #expect(clock.sleepingTaskCount == 0)
    }

    @Test func cancellingTaskSleepRemovesManualClockWaiter() async throws {
        let clock = ManualRuntimeClock()
        let interpreter = Interpreter(runtimeClock: clock)
        let execution = Task { @MainActor in
            try await interpreter.runAsync(source: """
            let sleeper = Task {
                do {
                    try await Task.sleep(nanoseconds: 10)
                    return "completed"
                } catch is CancellationError {
                    return "cancelled"
                }
            }
            await sleeper.value
            """)
        }

        var sleeper: RuntimeTaskHandle?
        for _ in 0..<1_000 {
            sleeper = interpreter.scheduledTasks.first {
                $0.kind == .unstructured && $0.suspension != nil
            }
            if sleeper != nil { break }
            await Task.yield()
        }

        let handle = try #require(sleeper)
        #expect(handle.state == .waiting)
        #expect(handle.suspension == .sleeping(
            until: RuntimeInstant(nanoseconds: 10)))
        #expect(clock.sleepingTaskCount == 1)

        handle.cancel()
        let result = try await execution.value
        #expect(result.stringValue == "cancelled")
        #expect(handle.state == .succeeded)
        #expect(handle.isCancelled)
        #expect(handle.cancellation.isObserved)
        #expect(handle.suspension == nil)
        #expect(clock.now == .zero)
        #expect(clock.sleepingTaskCount == 0)
    }

    @Test func taskYieldRecordsSuspensionAndLetsSiblingProgress() async throws {
        let interpreter = Interpreter()
        let gate = YieldProgressGate()
        interpreter.globals.define("holdAfterYieldProgress", .hostFunction(
            HostFunction(
                name: "holdAfterYieldProgress",
                asyncInvoke: { _, _ in
                    gate.reached = true
                    while !gate.released { await Task.yield() }
                    return .void
                }
            )
        ))
        let execution = Task { @MainActor in
            try await interpreter.runAsync(source: """
            @MainActor
            final class YieldState {
                var workerRan = false
            }

            let state = YieldState()
            let worker = Task {
                state.workerRan = true
            }
            while !state.workerRan {
                await Task.yield()
            }
            await holdAfterYieldProgress()
            "completed"
            """)
        }

        var root: RuntimeTaskRecord?
        for _ in 0..<1_000 {
            root = interpreter.concurrencyRuntime.records.values.first {
                $0.kind == .root
            }
            if gate.reached { break }
            await Task.yield()
        }

        let record = try #require(root)
        #expect(gate.reached)
        #expect(record.suspensionHistory.contains(.yielding))

        gate.released = true
        let result = try await execution.value
        #expect(result.stringValue == "completed")
        #expect(record.state == .succeeded)
        #expect(record.suspension == nil)
    }

    @Test func taskCancellationHandlerUsesCancellingTaskContextAndCleansUp()
        async throws {
        let interpreter = Interpreter()
        var handlerContextID: RuntimeTaskID?
        var handlerObservedCancellation: Bool?
        interpreter.globals.define(
            "recordCancellationHandlerContext",
            .hostFunction(HostFunction(
                name: "recordCancellationHandlerContext",
                invoke: { _, _ in
                    handlerContextID = interpreter.evaluationTaskContext
                        .runtimeTaskID
                    handlerObservedCancellation = Task.isCancelled
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        final class HandlerState {
            var started = false
        }

        let state = HandlerState()
        let worker = Task {
            await withTaskCancellationHandler(operation: {
                state.started = true
                while !Task.isCancelled {
                    await Task.yield()
                }
                return "done"
            }, onCancel: {
                recordCancellationHandlerContext()
            })
        }
        while !state.started {
            await Task.yield()
        }
        worker.cancel()
        worker.cancel()
        await worker.value
        """)

        guard case .host(let payload)? = interpreter.globals.lookup("worker"),
              let handle = payload as? RuntimeTaskHandle else {
            Issue.record("expected retained worker task handle")
            return
        }
        #expect(result.stringValue == "done")
        #expect(handlerContextID == handle.parent)
        #expect(handlerObservedCancellation == false)
        #expect(handle.cancellationHandlerInvocationCount == 1)
        #expect(handle.cancellationHandlerCount == 0)
        #expect(handle.isCancelled)
        #expect(handle.state == .succeeded)
    }

    @Test func preCancelledTaskRegistersHandlerBeforeOperationAndCleansUp()
        async throws {
        let interpreter = Interpreter()
        var handlerCallCount = 0
        var handlerContextID: RuntimeTaskID?
        var handlerObservedCancellation: Bool?
        var operationContextID: RuntimeTaskID?
        var operationObservedCancellation: Bool?
        var operationObservedHandler = false
        interpreter.globals.define(
            "recordPreCancelledHandlerContext",
            .hostFunction(HostFunction(
                name: "recordPreCancelledHandlerContext",
                invoke: { _, _ in
                    handlerCallCount += 1
                    handlerContextID = interpreter.evaluationTaskContext
                        .runtimeTaskID
                    handlerObservedCancellation = Task.isCancelled
                    return .void
                })))
        interpreter.globals.define(
            "preCancelledOperationResult",
            .hostFunction(HostFunction(
                name: "preCancelledOperationResult",
                invoke: { _, _ in
                    operationContextID = interpreter.evaluationTaskContext
                        .runtimeTaskID
                    operationObservedCancellation = Task.isCancelled
                    operationObservedHandler = handlerCallCount == 1
                    return .string(Task.isCancelled
                        ? "operation-cancelled" : "operation-active")
                })))

        let result = try await interpreter.runAsync(source: """
        let worker = Task {
            await withTaskCancellationHandler(operation: {
                preCancelledOperationResult()
            }, onCancel: {
                recordPreCancelledHandlerContext()
            })
        }
        worker.cancel()
        worker.cancel()
        await worker.value
        """)

        guard case .host(let payload)? = interpreter.globals.lookup("worker"),
              let handle = payload as? RuntimeTaskHandle else {
            Issue.record("expected retained worker task handle")
            return
        }
        #expect(result.stringValue == "operation-cancelled")
        #expect(handlerCallCount == 1)
        #expect(handlerContextID == handle.id)
        #expect(handlerObservedCancellation == true)
        #expect(operationContextID == handle.id)
        #expect(operationObservedCancellation == true)
        #expect(operationObservedHandler)
        #expect(handle.cancellationHandlerInvocationCount == 1)
        #expect(handle.cancellationHandlerCount == 0)
        #expect(handle.isCancelled)
        #expect(handle.state == .succeeded)
    }

    @Test func nestedCancellationHandlersRunInnerFirstAndCleanUp()
        async throws {
        let interpreter = Interpreter()
        var started = false
        var events: [(String, RuntimeTaskID?, Bool)] = []
        interpreter.globals.define(
            "markNestedHandlerStarted",
            .hostFunction(HostFunction(
                name: "markNestedHandlerStarted",
                invoke: { _, _ in
                    started = true
                    return .void
                })))
        interpreter.globals.define(
            "nestedHandlerHasStarted",
            .hostFunction(HostFunction(
                name: "nestedHandlerHasStarted",
                invoke: { _, _ in .bool(started) })))
        interpreter.globals.define(
            "recordNestedHandlerEvent",
            .hostFunction(HostFunction(
                name: "recordNestedHandlerEvent",
                invoke: { arguments, _ in
                    events.append((
                        arguments.positional(0)?.stringValue ?? "missing",
                        interpreter.evaluationTaskContext.runtimeTaskID,
                        Task.isCancelled))
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        let worker = Task {
            await withTaskCancellationHandler(operation: {
                await withTaskCancellationHandler(operation: {
                    markNestedHandlerStarted()
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    recordNestedHandlerEvent("operation")
                    return "done"
                }, onCancel: {
                    recordNestedHandlerEvent("inner")
                })
            }, onCancel: {
                recordNestedHandlerEvent("outer")
            })
        }
        while !nestedHandlerHasStarted() {
            await Task.yield()
        }
        worker.cancel()
        worker.cancel()
        await worker.value
        """)

        guard case .host(let payload)? = interpreter.globals.lookup("worker"),
              let handle = payload as? RuntimeTaskHandle else {
            Issue.record("expected retained worker task handle")
            return
        }
        #expect(result.stringValue == "done")
        #expect(events.map(\.0) == ["inner", "outer", "operation"])
        #expect(events.map(\.1) == [handle.parent, handle.parent, handle.id])
        #expect(events.map(\.2) == [false, false, true])
        #expect(handle.cancellationHandlerInvocationCount == 2)
        #expect(handle.cancellationHandlerCount == 0)
        #expect(handle.isCancelled)
        #expect(handle.state == .succeeded)
    }

    @Test func cancellationHandlersAreRemovedAfterNormalAndThrowingExit()
        async throws {
        let interpreter = Interpreter()
        var exitedScopes: Set<String> = []
        var exitObservations: [(String, RuntimeTaskID?, Int)] = []
        var unexpectedHandlers: [String] = []
        interpreter.globals.define(
            "markHandlerScopeExit",
            .hostFunction(HostFunction(
                name: "markHandlerScopeExit",
                invoke: { arguments, _ in
                    let label = arguments.positional(0)?.stringValue ?? "missing"
                    let taskID = interpreter.evaluationTaskContext.runtimeTaskID
                    let count = taskID.flatMap {
                        interpreter.concurrencyRuntime.records[$0]?
                            .activeCancellationHandlerCount
                    } ?? -1
                    exitObservations.append((label, taskID, count))
                    exitedScopes.insert(label)
                    return .void
                })))
        interpreter.globals.define(
            "handlerScopeExited",
            .hostFunction(HostFunction(
                name: "handlerScopeExited",
                invoke: { arguments, _ in
                    .bool(exitedScopes.contains(
                        arguments.positional(0)?.stringValue ?? "missing"))
                })))
        interpreter.globals.define(
            "recordUnexpectedScopeHandler",
            .hostFunction(HostFunction(
                name: "recordUnexpectedScopeHandler",
                invoke: { arguments, _ in
                    unexpectedHandlers.append(
                        arguments.positional(0)?.stringValue ?? "missing")
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        enum HandlerScopeError: Error {
            case expected
        }

        let normal = Task {
            let value = await withTaskCancellationHandler(operation: {
                return "normal"
            }, onCancel: {
                recordUnexpectedScopeHandler("normal")
            })
            markHandlerScopeExit("normal")
            while !Task.isCancelled {
                await Task.yield()
            }
            return value
        }
        while !handlerScopeExited("normal") {
            await Task.yield()
        }
        normal.cancel()
        let normalValue = await normal.value

        let throwing = Task {
            var value = "unexpected-success"
            do {
                _ = try await withTaskCancellationHandler(operation: {
                    () async throws -> String in
                    throw HandlerScopeError.expected
                }, onCancel: {
                    recordUnexpectedScopeHandler("throwing")
                })
            } catch HandlerScopeError.expected {
                value = "throwing"
            } catch {
                value = "unexpected-error"
            }
            markHandlerScopeExit("throwing")
            while !Task.isCancelled {
                await Task.yield()
            }
            return value
        }
        while !handlerScopeExited("throwing") {
            await Task.yield()
        }
        throwing.cancel()
        normalValue + "," + (await throwing.value)
        """)

        guard case .host(let normalPayload)? = interpreter.globals.lookup("normal"),
              let normal = normalPayload as? RuntimeTaskHandle,
              case .host(let throwingPayload)? = interpreter.globals.lookup("throwing"),
              let throwing = throwingPayload as? RuntimeTaskHandle else {
            Issue.record("expected both retained task handles")
            return
        }
        #expect(result.stringValue == "normal,throwing")
        #expect(exitObservations.map(\.0) == ["normal", "throwing"])
        #expect(exitObservations.map(\.1) == [normal.id, throwing.id])
        #expect(exitObservations.map(\.2) == [0, 0])
        #expect(unexpectedHandlers.isEmpty)
        #expect(normal.cancellationHandlerInvocationCount == 0)
        #expect(throwing.cancellationHandlerInvocationCount == 0)
        #expect(normal.cancellationHandlerCount == 0)
        #expect(throwing.cancellationHandlerCount == 0)
        #expect(normal.isCancelled && throwing.isCancelled)
        #expect(normal.state == .succeeded && throwing.state == .succeeded)
    }

    @Test func labeledSuspendingClosureBodyRemainsDeferredUntilInvocation()
        async throws {
        let interpreter = Interpreter()
        var events: [String] = []
        interpreter.globals.define(
            "recordDeferredBody",
            .hostFunction(HostFunction(
                name: "recordDeferredBody",
                asyncInvoke: { _, _ in
                    events.append("body")
                    return .void
                })))
        interpreter.globals.define(
            "runDeferredOperation",
            .hostFunction(HostFunction(
                name: "runDeferredOperation",
                asyncInvoke: { arguments, context in
                    events.append("gateway")
                    guard let operation = arguments.closure(
                        labeled: "operation") else {
                        throw RuntimeError(message: "missing operation")
                    }
                    let value = try await context.callClosureAsync(
                        operation, arguments: [])
                    events.append("after")
                    return value
                })))

        let result = try await interpreter.runAsync(source: """
        await runDeferredOperation(operation: {
            await recordDeferredBody()
            return "done"
        })
        """)

        #expect(result.stringValue == "done")
        #expect(events == ["gateway", "body", "after"])
    }

    @Test func synchronousHostCallbackEntersConcurrencyRuntime() async throws {
        let interpreter = Interpreter()
        var observedCallbackKind: RuntimeTaskKind?
        interpreter.globals.define(
            "observeCallbackRuntime",
            .hostFunction(HostFunction(
                name: "observeCallbackRuntime"
            ) { _, _ in
                guard let taskID = interpreter.evaluationTaskContext.runtimeTaskID else {
                    return .void
                }
                observedCallbackKind = interpreter.concurrencyRuntime
                    .records[taskID]?.kind
                return .void
            }))
        let action = try interpreter.run(source: """
        @MainActor
        final class CallbackModel {
            var phase = "idle"

            func start() {
                observeCallbackRuntime()
                phase = "started"
                Task.detached {
                    let total = await withTaskGroup(of: Int.self) { group in
                        group.addTask { 1 }
                        group.addTask { 2 }
                        let first = await group.next() ?? 0
                        let second = await group.next() ?? 0
                        return first + second
                    }
                    await self.finish(total)
                }
            }

            func finish(_ total: Int) {
                phase = "done-\\(total)"
            }
        }

        let callbackModel = CallbackModel()

        func makeCallback() -> () -> Void {
            {
                callbackModel.start()
            }
        }

        makeCallback()
        """)
        let closure = try #require(action.closureValue)
        guard case .instance(let model)? = interpreter.globals.lookup(
            "callbackModel") else {
            Issue.record("callback model missing")
            return
        }

        _ = try interpreter.callHostCallback(closure, arguments: [])

        // A native synchronous action mutates state before returning. Work it
        // creates may continue independently through the concurrency runtime.
        #expect(observedCallbackKind == .hostCallback)
        #expect(model.box(for: "phase")?.value.stringValue == "started")
        for _ in 0..<1_000
        where model.box(for: "phase")?.value.stringValue != "done-3" {
            await Task.yield()
        }
        #expect(model.box(for: "phase")?.value.stringValue == "done-3")
        for _ in 0..<1_000
        where !interpreter.scheduledTasks.isEmpty
            || interpreter.concurrencyRuntime.activeRecordCount != 0 {
            await Task.yield()
        }
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
