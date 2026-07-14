import Testing
@testable import SwiftInterpreter

@Suite("Generated task-group surface")
struct TaskGroupSurfaceTests {
    @Test func activeInterfaceAliasesResolveToRuntimeIntrinsics() {
        let dispatch = GeneratedConcurrencySurface.taskGroupDispatch
        #expect(dispatch["addTask"] == .addTask)
        #expect(dispatch["async"] == .addTask)
        #expect(dispatch["spawn"] == .addTask)
        #expect(dispatch["add"] == .addTaskUnlessCancelled)
        #expect(dispatch["asyncUnlessCancelled"] == .addTaskUnlessCancelled)
        #expect(dispatch["spawnUnlessCancelled"] == .addTaskUnlessCancelled)
        #expect(dispatch["isEmpty"] == .isEmpty)
        #expect(GeneratedConcurrencySurface.knownTaskGroupMembers.contains(
            "nextResult"))
        #expect(dispatch["nextResult"] == nil)
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
}
