import Testing
@testable import SwiftInterpreter

@Suite("Generated task-group surface")
struct TaskGroupSurfaceTests {
    @Test func activeInterfaceAliasesResolveToRuntimeIntrinsics() {
        let dispatch = try! #require(
            GeneratedConcurrencySurface.taskGroupDispatch["TaskGroup"])
        let throwing = try! #require(
            GeneratedConcurrencySurface.taskGroupDispatch[
                "ThrowingTaskGroup"])
        let discarding = try! #require(
            GeneratedConcurrencySurface.taskGroupDispatch[
                "DiscardingTaskGroup"])
        #expect(dispatch["addTask"] == .addTask)
        #expect(dispatch["async"] == .addTask)
        #expect(dispatch["spawn"] == .addTask)
        #expect(dispatch["add"] == .addTaskUnlessCancelled)
        #expect(dispatch["asyncUnlessCancelled"] == .addTaskUnlessCancelled)
        #expect(dispatch["spawnUnlessCancelled"] == .addTaskUnlessCancelled)
        #expect(throwing["asyncUnlessCancelled"] == .addTaskUnlessCancelled)
        #expect(throwing["spawnUnlessCancelled"] == .addTaskUnlessCancelled)
        #expect(dispatch["isEmpty"] == .isEmpty)
        #expect(dispatch["waitForAll"] == .waitForAll)
        #expect(throwing["waitForAll"] == .waitForAll)
        #expect(dispatch["nextResult"] == nil)
        #expect(throwing["nextResult"] == .nextResult)
        #expect(dispatch["makeAsyncIterator"] == .makeAsyncIterator)
        #expect(throwing["makeAsyncIterator"] == .makeAsyncIterator)
        #expect(GeneratedConcurrencySurface.taskGroupIteratorIntrinsic(
            typeName: "TaskGroup", memberName: "next") == .next)
        #expect(GeneratedConcurrencySurface.taskGroupIteratorIntrinsic(
            typeName: "TaskGroup", memberName: "cancel") == .cancel)
        #expect(GeneratedConcurrencySurface.taskGroupIteratorIntrinsic(
            typeName: "ThrowingTaskGroup", memberName: "next") == .next)
        #expect(GeneratedConcurrencySurface.taskGroupIteratorIntrinsic(
            typeName: "ThrowingTaskGroup", memberName: "cancel") == .cancel)
        #expect(GeneratedConcurrencySurface.taskGroupIteratorMemberDeclarations[
            "TaskGroup"]?["next"]?.count == 2)
        #expect(GeneratedConcurrencySurface.taskGroupIteratorMemberDeclarations[
            "ThrowingTaskGroup"]?["next"]?.count == 2)
        let ordinaryWaitDeclarations = try! #require(
            GeneratedConcurrencySurface.taskGroupMemberDeclarations[
                "TaskGroup"]?["waitForAll"])
        let throwingWaitDeclarations = try! #require(
            GeneratedConcurrencySurface.taskGroupMemberDeclarations[
                "ThrowingTaskGroup"]?["waitForAll"])
        #expect(ordinaryWaitDeclarations.count == 1)
        #expect(throwingWaitDeclarations.count == 1)
        let ordinaryWait = try! #require(ordinaryWaitDeclarations.first)
        let throwingWait = try! #require(throwingWaitDeclarations.first)
        #expect(ordinaryWait.isAsync)
        #expect(ordinaryWait.throwsKind == .nonThrowing)
        #expect(throwingWait.isAsync)
        #expect(throwingWait.throwsKind == .throwing)
        #expect(ordinaryWait.parameters.count == 1)
        #expect(throwingWait.parameters.count == 1)
        #expect(ordinaryWait.parameters.first?.label == "isolation")
        #expect(throwingWait.parameters.first?.label == "isolation")
        #expect(GeneratedConcurrencySurface.knownTaskGroupMembers[
            "ThrowingTaskGroup"]?.contains("nextResult") == true)
        #expect(discarding["addTask"] == .addTask)
        #expect(discarding["isEmpty"] == .isEmpty)
        #expect(discarding["next"] == nil)
        #expect(discarding["waitForAll"] == nil)
        #expect(GeneratedConcurrencySurface.topLevelFunctionDispatch == [
            "_isolatedParameter_withTaskPriorityEscalationHandler":
                .withTaskPriorityEscalationHandler,
            "async": .unstructuredTask,
            "asyncDetached": .detachedTask,
            "detach": .detachedTask,
            "extractIsolation": .extractIsolation,
            "withCheckedContinuation": .withCheckedContinuation,
            "withCheckedThrowingContinuation": .withCheckedThrowingContinuation,
            "withDiscardingTaskGroup": .withDiscardingTaskGroup,
            "withTaskCancellationHandler": .withTaskCancellationHandler,
            "withTaskExecutorPreference": .withTaskExecutorPreference,
            "withTaskGroup": .withTaskGroup,
            "withTaskPriorityEscalationHandler":
                .withTaskPriorityEscalationHandler,
            "withThrowingDiscardingTaskGroup":
                .withThrowingDiscardingTaskGroup,
            "withThrowingTaskGroup": .withThrowingTaskGroup,
            "withUnsafeCurrentTask": .withCurrentTaskCapability,
        ])
        #expect(GeneratedConcurrencySurface.knownTopLevelFunctions.contains(
            "withUnsafeCurrentTask"))
        let interpreter = Interpreter()
        for sourceName in GeneratedConcurrencySurface
                .topLevelFunctionDispatch.keys {
            guard case .hostFunction(let function)? =
                    interpreter.globals.lookup(sourceName) else {
                Issue.record("generated concurrency function was not registered")
                continue
            }
            #expect(function.name == sourceName)
        }
    }

    @Test func topLevelAsyncUsesCanonicalUnstructuredTaskRuntime() async throws {
        let interpreter = Interpreter()
        _ = try await interpreter.runAsync(source: """
        let aliasTask = async(priority: .utility) {
            await Task.yield()
            return "value"
        }
        """)

        guard case .host(let payload)? = interpreter.globals.lookup("aliasTask"),
              let handle = payload as? RuntimeTaskHandle else {
            Issue.record("expected top-level async to return a task handle")
            return
        }
        #expect(handle.kind == .unstructured)
        #expect(handle.parent != nil)
        #expect(handle.basePriority == .low)
        #expect(handle.state == .succeeded)
        #expect(handle.result?.stringValue == "value")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func topLevelAsyncFailsClosedInSynchronousCompatibility() {
        do {
            _ = try Interpreter().run(source: "async { 1 }")
            Issue.record(
                "top-level async ran through synchronous compatibility")
        } catch {
            #expect(String(describing: error).contains(
                "Task creation requires runAsync"))
        }
    }

    @Test func topLevelDetachedAliasesUseCanonicalDetachedRuntime() async throws {
        let interpreter = Interpreter()
        _ = try await interpreter.runAsync(source: """
        let asyncDetachedHandle = asyncDetached(priority: .utility) {
            await Task.yield()
            return "asyncDetached"
        }
        let detachHandle = detach(priority: .background) {
            await Task.yield()
            return "detach"
        }
        """)

        func handle(_ name: String) throws -> RuntimeTaskHandle {
            guard case .host(let payload)? = interpreter.globals.lookup(name),
                  let handle = payload as? RuntimeTaskHandle else {
                throw RuntimeError(message:
                    "expected \(name) to contain a task handle")
            }
            return handle
        }

        let asyncDetached = try handle("asyncDetachedHandle")
        let detach = try handle("detachHandle")
        for task in [asyncDetached, detach] {
            #expect(task.kind == .detached)
            #expect(task.parent == nil)
            #expect(task.taskLocalCount == 0)
            #expect(task.state == .succeeded)
        }
        #expect(asyncDetached.basePriority == .low)
        #expect(asyncDetached.result?.stringValue == "asyncDetached")
        #expect(detach.basePriority == .background)
        #expect(detach.result?.stringValue == "detach")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func topLevelDetachedAliasesFailClosedInSynchronousCompatibility() {
        for source in ["asyncDetached { 1 }", "detach { 1 }"] {
            do {
                _ = try Interpreter().run(source: source)
                Issue.record(
                    "top-level detached alias ran through sync compatibility")
            } catch {
                #expect(String(describing: error).contains(
                    "Task creation requires runAsync"))
            }
        }
    }

    @Test func nonNilTaskGroupExecutorPreferenceFailsClosed() async {
        do {
            _ = try await Interpreter().runAsync(source: """
            final class ProbeTaskExecutor: TaskExecutor {
                func enqueue(_ job: consuming ExecutorJob) {
                    globalConcurrentExecutor.enqueue(job)
                }
            }
            await withTaskGroup(of: Int.self) { group in
                let executor = ProbeTaskExecutor()
                group.addTask(executorPreference: executor) { 7 }
                return await group.next() ?? -1
            }
            """)
            Issue.record(
                "non-nil task-group executor preference was silently ignored")
        } catch {
            #expect(String(describing: error).contains(
                "TaskGroup.addTask(executorPreference:) is not supported yet"))
        }
    }

    @Test func nonNilConditionalTaskGroupExecutorPreferenceFailsClosed() async {
        do {
            _ = try await Interpreter().runAsync(source: """
            final class ProbeTaskExecutor: TaskExecutor {
                func enqueue(_ job: consuming ExecutorJob) {
                    globalConcurrentExecutor.enqueue(job)
                }
            }
            await withTaskGroup(of: Int.self) { group in
                let executor = ProbeTaskExecutor()
                let accepted = group.addTaskUnlessCancelled(
                    executorPreference: executor
                ) { 7 }
                return accepted ? (await group.next() ?? -1) : -2
            }
            """)
            Issue.record(
                "non-nil conditional executor preference was silently ignored")
        } catch {
            #expect(String(describing: error).contains(
                "TaskGroup.addTaskUnlessCancelled(executorPreference:) "
                    + "is not supported yet"))
        }
    }

    @Test func immediateTaskGroupChildCompletesBeforeAddReturns() async throws {
        let interpreter = Interpreter()
        var observedMembershipBeforeSourceEntry = false
        interpreter.globals.define(
            "inspectImmediateTaskGroupMembership",
            .hostFunction(HostFunction(
                name: "inspectImmediateTaskGroupMembership"
            ) { _, context in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let child = interpreter.concurrencyRuntime
                        .records[childID],
                      let groupID = child.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID],
                      group.childTaskIDs.contains(childID),
                      group.structuredScope.childTaskIDs.contains(childID),
                      child.executorPreference == .mainActor,
                      context.sourceExecutor == .mainActor
                else {
                    throw RuntimeError(message:
                        "immediate child lost ownership or operation actor")
                }
                observedMembershipBeforeSourceEntry = true
                return .void
            }))
        let result = try await interpreter.runAsync(source: """
        @MainActor
        final class ImmediateRecorder {
            var value = "pending"

            func record(_ newValue: String) {
                value = newValue
            }
        }

        @MainActor
        func immediateCompletionProbe() async -> String {
            let recorder = ImmediateRecorder()
            return await withTaskGroup(of: Int.self) { group in
                group.addImmediateTask(
                    name: "immediate-child",
                    executorPreference: nil
                ) {
                    inspectImmediateTaskGroupMembership()
                    recorder.record("started:" + (Task.name ?? "nil"))
                    return 7
                }
                let snapshot = recorder.value
                let child = await group.next() ?? -1
                return snapshot + ":" + String(child)
            }
        }

        await immediateCompletionProbe()
        """)

        #expect(result.stringValue == "started:immediate-child:7")
        #expect(observedMembershipBeforeSourceEntry)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func immediateTaskGroupChildPreservesExecutorAcrossSuspension()
            async throws {
        let interpreter = Interpreter()
        var phases: [String] = []
        interpreter.globals.define(
            "inspectImmediateGroupExecutor",
            .hostFunction(HostFunction(
                name: "inspectImmediateGroupExecutor"
            ) { arguments, context in
                guard let phase = arguments.positional(0)?.stringValue,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let record = interpreter.concurrencyRuntime.records[taskID],
                      record.kind == .groupChild,
                      record.executorPreference == .mainActor,
                      context.sourceExecutor == .mainActor
                else {
                    throw RuntimeError(message:
                        "immediate group child lost its operation executor")
                }
                phases.append(phase)
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        func immediateGroupExecutorProbe() async -> Int {
            return await withTaskGroup(of: Int.self) { group in
                group.addImmediateTask(executorPreference: nil) {
                    inspectImmediateGroupExecutor("before")
                    await Task.yield()
                    inspectImmediateGroupExecutor("after")
                    return 7
                }
                return await group.next() ?? -1
            }
        }
        return await immediateGroupExecutorProbe()
        """)

        #expect(result.intValue == 7)
        #expect(phases == ["before", "after"])
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func synchronouslyThrowingImmediateGroupChildPublishesFailure()
            async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        enum ImmediateGroupFailure: Error { case boom }

        @MainActor
        func immediateGroupFailureProbe() async -> String {
            return await withThrowingTaskGroup(of: Int.self) { group in
                group.addImmediateTask(executorPreference: nil) {
                    throw ImmediateGroupFailure.boom
                }
                do {
                    _ = try await group.next()
                    return "missed"
                } catch ImmediateGroupFailure.boom {
                    return "boom"
                } catch {
                    return "wrong-error"
                }
            }
        }
        return await immediateGroupFailureProbe()
        """)

        #expect(result.stringValue == "boom")
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func immediateTaskGroupChildRejectsUnsupportedOperationExecutors()
            async {
        for member in ["addImmediateTask", "addImmediateTaskUnlessCancelled"] {
            for source in [
                """
                @concurrent
                nonisolated func operation() async -> Int { 1 }
                return await withTaskGroup(of: Int.self) { group in
                    group.\(member)(
                        executorPreference: nil, operation: operation
                    )
                    return await group.next() ?? -1
                }
                """,
                """
                @concurrent
                nonisolated func construct() async -> Int {
                    return await withTaskGroup(of: Int.self) { group in
                        group.\(member)(executorPreference: nil) { 1 }
                        return await group.next() ?? -1
                    }
                }
                return await construct()
                """,
                """
                nonisolated func operationFactory() -> () async -> Int {
                    { 1 }
                }
                @MainActor
                func construct() async -> Int {
                    let operation = operationFactory()
                    return await withTaskGroup(of: Int.self) { group in
                        group.\(member)(
                            executorPreference: nil, operation: operation
                        )
                        return await group.next() ?? -1
                    }
                }
                return await construct()
                """,
            ] {
                do {
                    _ = try await Interpreter().runAsync(source: source)
                    Issue.record(
                        "TaskGroup.\(member) accepted an unsupported operation executor")
                } catch {
                    #expect(String(describing: error).contains(
                        "TaskGroup.\(member) currently requires a "
                            + "MainActor-inherited operation invoked from "
                            + "MainActor"))
                }
            }
        }
    }

    @Test func nonNilImmediateTaskGroupExecutorPreferenceFailsClosed() async {
        do {
            _ = try await Interpreter().runAsync(source: """
            final class ProbeTaskExecutor: TaskExecutor {
                func enqueue(_ job: consuming ExecutorJob) {
                    globalConcurrentExecutor.enqueue(job)
                }
            }
            await withTaskGroup(of: Int.self) { group in
                let executor = ProbeTaskExecutor()
                group.addImmediateTask(executorPreference: executor) { 7 }
                return await group.next() ?? -1
            }
            """)
            Issue.record(
                "non-nil immediate executor preference was silently ignored")
        } catch {
            #expect(String(describing: error).contains(
                "TaskGroup.addImmediateTask(executorPreference:) "
                    + "is not supported yet"))
        }
    }

    @Test func cancelledImmediateConditionalAddSkipsExecutorPreference()
            async throws {
        let result = try await Interpreter().runAsync(source: """
        final class ProbeTaskExecutor: TaskExecutor {
            func enqueue(_ job: consuming ExecutorJob) {
                globalConcurrentExecutor.enqueue(job)
            }
        }
        await withTaskGroup(of: Int.self) { group in
            group.cancelAll()
            let executor = ProbeTaskExecutor()
            let accepted = group.addImmediateTaskUnlessCancelled(
                executorPreference: executor
            ) { 7 }
            return accepted ? -1 : 0
        }
        """)

        #expect(result.intValue == 0)
    }

    @Test func preCancelledUnconditionalImmediateChildObservesCancellation()
            async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: """
        await withTaskGroup(of: String.self) { group in
            group.cancelAll()
            group.addImmediateTask(executorPreference: nil) {
                let prefix = Task.isCancelled
                let check: String
                do {
                    try Task.checkCancellation()
                    check = "missed"
                } catch is CancellationError {
                    check = "caught"
                }
                await Task.yield()
                return String(prefix) + ":" + check + ":"
                    + String(Task.isCancelled)
            }
            return await group.next() ?? "missing"
        }
        """)

        #expect(result.stringValue == "true:caught:true")
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func cancelledConditionalAddSkipsExecutorPreference() async throws {
        let result = try await Interpreter().runAsync(source: """
        final class ProbeTaskExecutor: TaskExecutor {
            func enqueue(_ job: consuming ExecutorJob) {
                globalConcurrentExecutor.enqueue(job)
            }
        }
        await withTaskGroup(of: Int.self) { group in
            group.cancelAll()
            let executor = ProbeTaskExecutor()
            let accepted = group.addTaskUnlessCancelled(
                executorPreference: executor
            ) { 7 }
            return accepted ? "accepted" : "rejected"
        }
        """)

        #expect(result.stringValue == "rejected")
    }

    @Test func isEmptyTracksUnconsumedChildrenThroughLegacyAlias() async throws {
        let interpreter = Interpreter()
        var observedGroup: RuntimeTaskGroupRecord?
        interpreter.globals.define(
            "inspectIsEmptyGroupChild",
            .hostFunction(HostFunction(
                name: "inspectIsEmptyGroupChild"
            ) { _, _ in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let groupID = interpreter.concurrencyRuntime
                        .records[childID]?.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID] else {
                    throw RuntimeError(message:
                        "task-group child lost isEmpty ownership")
                }
                observedGroup = group
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        func emptyState(_ value: Bool) -> String {
            value ? "empty" : "nonempty"
        }
        func taskGroupIsEmptyProbe() async -> String {
            await withTaskGroup(of: Int.self) { group in
                let before = emptyState(group.isEmpty)
                group.async {
                    inspectIsEmptyGroupChild()
                    await Task.sleep(1)
                    return 7
                }
                let afterAdd = emptyState(group.isEmpty)
                let value = await group.next() ?? -1
                let afterNext = emptyState(group.isEmpty)
                return "\\(before):\\(afterAdd):\\(afterNext):\\(value)"
            }
        }
        await taskGroupIsEmptyProbe()
        """)

        let group = try #require(observedGroup)
        #expect(result.stringValue == "empty:nonempty:empty:7")
        #expect(group.childTaskIDs.count == 1)
        #expect(group.completedChildTaskIDs == group.childTaskIDs)
        #expect(group.consumedChildTaskIDs == Set(group.childTaskIDs))
        #expect(group.isEmpty)
        #expect(group.pendingCompletedChildCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func discardingGroupConsumesSuccessfulChildOutcome() async throws {
        let interpreter = Interpreter()
        var observedGroup: RuntimeTaskGroupRecord?
        var observedChild: RuntimeTaskRecord?
        interpreter.globals.define(
            "inspectDiscardingChild",
            .hostFunction(HostFunction(
                name: "inspectDiscardingChild"
            ) { _, _ in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let child = interpreter.concurrencyRuntime
                        .records[childID],
                      let groupID = child.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID] else {
                    throw RuntimeError(message:
                        "discarding child lost task-group ownership")
                }
                observedChild = child
                observedGroup = group
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        func discardingCompletionProbe() async -> String {
            await withDiscardingTaskGroup(returning: String.self) { group in
                let before = group.isEmpty
                group.addTask {
                    inspectDiscardingChild()
                }
                let afterAdd = group.isEmpty
                while !group.isEmpty {
                    await Task.yield()
                }
                return "\\(before):\\(afterAdd):\\(group.isEmpty)"
            }
        }
        await discardingCompletionProbe()
        """)

        let group = try #require(observedGroup)
        let child = try #require(observedChild)
        #expect(result.stringValue == "true:false:true")
        #expect(group.kind == .discarding)
        #expect(group.childTaskIDs == [child.id])
        #expect(group.completedChildTaskIDs == [child.id])
        #expect(group.consumedChildTaskIDs == Set([child.id]))
        #expect(group.pendingCompletedChildCount == 0)
        #expect(group.isEmpty)
        #expect(group.firstDiscardingFailure == nil)
        #expect(child.state == .succeeded)
        #expect(child.outcome == nil)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingDiscardingGroupProjectsFirstChildFailure() async throws {
        let interpreter = Interpreter()
        var observedGroup: RuntimeTaskGroupRecord?
        var observedChild: RuntimeTaskRecord?
        var observedSibling: RuntimeTaskRecord?
        var siblingStarted = false
        interpreter.globals.define(
            "markThrowingDiscardingSibling",
            .hostFunction(HostFunction(
                name: "markThrowingDiscardingSibling"
            ) { _, _ in
                guard let siblingID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let sibling = interpreter.concurrencyRuntime
                        .records[siblingID] else {
                    throw RuntimeError(message:
                        "throwing discarding sibling lost runtime identity")
                }
                observedSibling = sibling
                siblingStarted = true
                return .void
            }))
        interpreter.globals.define(
            "waitForThrowingDiscardingSibling",
            .hostFunction(HostFunction(
                name: "waitForThrowingDiscardingSibling",
                asyncInvoke: { _, _ in
                    while !siblingStarted { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "inspectThrowingDiscardingChild",
            .hostFunction(HostFunction(
                name: "inspectThrowingDiscardingChild"
            ) { _, _ in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let child = interpreter.concurrencyRuntime
                        .records[childID],
                      let groupID = child.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID] else {
                    throw RuntimeError(message:
                        "throwing discarding child lost task-group ownership")
                }
                observedChild = child
                observedGroup = group
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        enum DiscardingBoom: Error { case child }
        func throwingDiscardingFailureProbe() async -> String {
            do {
                _ = try await withThrowingDiscardingTaskGroup(
                    returning: Int.self
                ) { group in
                    group.addTask {
                        markThrowingDiscardingSibling()
                        try await Task.sleep(for: .seconds(30))
                    }
                    group.addTask {
                        await waitForThrowingDiscardingSibling()
                        inspectThrowingDiscardingChild()
                        throw DiscardingBoom.child
                    }
                    return 42
                }
                return "missing"
            } catch DiscardingBoom.child {
                return "child"
            } catch {
                return "wrong"
            }
        }
        await throwingDiscardingFailureProbe()
        """)

        let group = try #require(observedGroup)
        let child = try #require(observedChild)
        let sibling = try #require(observedSibling)
        #expect(result.stringValue == "child")
        #expect(group.kind == .throwingDiscarding)
        #expect(group.childTaskIDs == [sibling.id, child.id])
        #expect(Set(group.completedChildTaskIDs) == Set(group.childTaskIDs))
        #expect(group.consumedChildTaskIDs == Set(group.childTaskIDs))
        #expect(group.pendingCompletedChildCount == 0)
        #expect(group.isEmpty)
        #expect(group.hasChildFailureCancellationRequest)
        #expect(group.firstDiscardingFailure != nil)
        #expect(child.state == .failed)
        #expect(child.outcome == nil)
        #expect(sibling.state == .cancelled)
        #expect(sibling.cancellation.sources == [.taskGroupChildFailure])
        #expect(sibling.outcome == nil)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func throwingDiscardingBodyFailureWinsAfterChildJoin() async throws {
        let interpreter = Interpreter()
        var observedGroup: RuntimeTaskGroupRecord?
        var observedChild: RuntimeTaskRecord?
        var childStarted = false
        interpreter.globals.define(
            "markDiscardingBodyFailureChild",
            .hostFunction(HostFunction(
                name: "markDiscardingBodyFailureChild"
            ) { _, _ in
                guard let childID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let child = interpreter.concurrencyRuntime
                        .records[childID],
                      let groupID = child.taskGroupID,
                      let group = interpreter.concurrencyRuntime
                        .taskGroups[groupID] else {
                    throw RuntimeError(message:
                        "body-failure child lost task-group ownership")
                }
                observedChild = child
                observedGroup = group
                childStarted = true
                return .void
            }))
        interpreter.globals.define(
            "waitForDiscardingBodyFailureChild",
            .hostFunction(HostFunction(
                name: "waitForDiscardingBodyFailureChild",
                asyncInvoke: { _, _ in
                    while !childStarted { await Task.yield() }
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
        enum DiscardingBodyBoom: Error { case body }
        func throwingDiscardingBodyFailureProbe() async -> String {
            do {
                _ = try await withThrowingDiscardingTaskGroup(
                    returning: Int.self
                ) { group in
                    group.addTask {
                        markDiscardingBodyFailureChild()
                        try await Task.sleep(for: .seconds(30))
                    }
                    await waitForDiscardingBodyFailureChild()
                    throw DiscardingBodyBoom.body
                }
                return "missing"
            } catch DiscardingBodyBoom.body {
                return "body"
            } catch {
                return "wrong"
            }
        }
        await throwingDiscardingBodyFailureProbe()
        """)

        let group = try #require(observedGroup)
        let child = try #require(observedChild)
        #expect(result.stringValue == "body")
        #expect(group.kind == .throwingDiscarding)
        #expect(group.hasDiscardingBodyFailureExit)
        #expect(!group.hasChildFailureCancellationRequest)
        #expect(group.firstDiscardingFailure == nil)
        #expect(group.completedChildTaskIDs == [child.id])
        #expect(group.consumedChildTaskIDs == Set([child.id]))
        #expect(group.isEmpty)
        #expect(child.state == .cancelled)
        #expect(child.cancellation.sources == [.structuredScopeExit])
        #expect(child.outcome == nil)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
