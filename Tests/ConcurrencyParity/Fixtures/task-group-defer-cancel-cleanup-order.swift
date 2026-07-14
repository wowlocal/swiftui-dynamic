import Foundation

@MainActor
var taskGroupDeferCleanupEvents: [String] = []

@MainActor
var taskGroupDeferCleanupChildStarted = false

@MainActor
func taskGroupDeferCleanupChild() async -> String {
    taskGroupDeferCleanupChildStarted = true
    taskGroupDeferCleanupEvents.append("child-start")
    do {
        try await Task.sleep(for: .seconds(30))
        taskGroupDeferCleanupEvents.append("child-finished")
        return "finished"
    } catch {
        let state = Task.isCancelled ? "child-cancelled" : "child-error"
        taskGroupDeferCleanupEvents.append(state)
        return state
    }
}

@MainActor
func taskGroupDeferCancelCleanupOrderProbe() async -> String {
    taskGroupDeferCleanupEvents = []
    taskGroupDeferCleanupChildStarted = false

    await withTaskGroup(of: String.self) { group in
        group.addTask {
            await taskGroupDeferCleanupChild()
        }
        while !taskGroupDeferCleanupChildStarted {
            await Task.yield()
        }
        defer {
            taskGroupDeferCleanupEvents.append("defer-cancel")
            group.cancelAll()
        }
        taskGroupDeferCleanupEvents.append("body-return")
    }
    taskGroupDeferCleanupEvents.append("after-scope")
    return taskGroupDeferCleanupEvents.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupDeferCancelCleanupOrderProbe()
}
