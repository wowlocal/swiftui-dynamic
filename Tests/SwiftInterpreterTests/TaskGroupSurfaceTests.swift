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
        #expect(dispatch["isEmpty"] == .isEmpty)
        #expect(dispatch["waitForAll"] == .waitForAll)
        #expect(throwing["waitForAll"] == .waitForAll)
        #expect(dispatch["nextResult"] == nil)
        #expect(throwing["nextResult"] == .nextResult)
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
            "withDiscardingTaskGroup": .withDiscardingTaskGroup,
            "withTaskCancellationHandler": .withTaskCancellationHandler,
            "withTaskGroup": .withTaskGroup,
            "withThrowingDiscardingTaskGroup":
                .withThrowingDiscardingTaskGroup,
            "withThrowingTaskGroup": .withThrowingTaskGroup,
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
