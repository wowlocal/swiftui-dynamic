import Testing
@testable import SwiftInterpreter

private struct NativeAsyncCounter {
    var value: Int

    mutating func bump() async {
        await Task.yield()
        value += 1
    }
}

private enum DetachedRuntimeProbeLocal {
    @TaskLocal static var value = "default"
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
        let nativeTask = Task { @MainActor in
            await Task.yield()
            if !Task.isCancelled { nativeRan = true }
        }
        nativeTask.cancel()
        await nativeTask.value

        let interpreter = Interpreter()
        let state = try await interpreter.runAsync(source: """
        class State { var ran = false }
        let state = State()
        let handle = Task { state.ran = true }
        handle.cancel()
        state
        """)

        guard case .instance(let instance) = state else {
            Issue.record("expected an interpreted State")
            return
        }
        #expect(instance.box(for: "ran")?.value.boolValue == nativeRan)
        guard case .host(let any)? = interpreter.globals.lookup("handle"),
              let handle = any as? RuntimeTaskHandle else {
            Issue.record("Task should return a runtime task handle")
            return
        }
        #expect(handle.state == .cancelled)
        #expect(handle.isCancelled)
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

        _ = try await interpreter.runAsync(
            source: """
            let cancellationPolicyHandle = Task {
                await waitForCancellationPolicy()
                "unexpected"
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
        #expect(handle.state == .cancelled)
        #expect(handle.isCancelled)
        #expect(handle.cancellation.sources.contains(.sessionPolicy))
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
        interpreter.globals.define("delayedText", .hostFunction(HostFunction(
            name: "delayedText",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))
        interpreter.globals.define("withValue", .hostFunction(HostFunction(
            name: "withValue",
            asyncInvoke: { arguments, context in
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
            await decorate(value)
        }
        """)

        #expect(result.stringValue == "inside!")
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
}
