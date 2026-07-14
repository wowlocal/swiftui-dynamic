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

        do {
            _ = try await interpreter.runAsync(source: """
            func cancelledThrowingWaitOwner() async throws -> String {
                try await withThrowingTaskGroup(of: String.self) { group in
                    group.cancelAll()
                    group.addTask {
                        try Task.checkCancellation()
                        return "missed"
                    }
                    try await group.waitForAll()
                    return "missed"
                }
            }
            try await cancelledThrowingWaitOwner()
            """)
            Issue.record("unprobed throwing wait cancellation unexpectedly succeeded")
        } catch let failure as RuntimeError {
            #expect(failure.message.contains(
                "waitForAll cancellation projection is not supported"))
        } catch {
            Issue.record("unexpected throwing wait cancellation error: \(error)")
        }

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

    @Test func throwingTaskGroupWaitKeepsScopeFailureSeparate() async throws {
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

        do {
            _ = try await interpreter.runAsync(source: """
            enum UnconsumedThrowingGroupError: Error {
                case failed
            }
            func unconsumedThrowingGroupOwner() async throws -> String {
                try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        throw UnconsumedThrowingGroupError.failed
                    }
                    return "body"
                }
            }
            try await unconsumedThrowingGroupOwner()
            """)
            Issue.record("unprobed throwing scope failure unexpectedly succeeded")
        } catch let failure as RuntimeError {
            #expect(failure.message.contains(
                "task-group scope-exit failure propagation is not supported"))
        } catch {
            Issue.record("unexpected throwing scope diagnostic: \(error)")
        }

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
}
