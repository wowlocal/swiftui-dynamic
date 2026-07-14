import Foundation

enum TaskGroupThrowingDeferCleanupError: Error {
    case failed
}

@MainActor
var taskGroupThrowingDeferEvents: [String] = []

@MainActor
var taskGroupThrowingDeferChildStarted = false

@MainActor
func taskGroupThrowingDeferChild() async -> String {
    taskGroupThrowingDeferChildStarted = true
    taskGroupThrowingDeferEvents.append("child-start")
    do {
        try await Task.sleep(for: .seconds(30))
        taskGroupThrowingDeferEvents.append("child-finished")
        return "finished"
    } catch {
        let state = Task.isCancelled ? "child-cancelled" : "child-error"
        taskGroupThrowingDeferEvents.append(state)
        return state
    }
}

@MainActor
func taskGroupThrowingDeferCleanupOrderProbe() async -> String {
    taskGroupThrowingDeferEvents = []
    taskGroupThrowingDeferChildStarted = false

    do {
        _ = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await taskGroupThrowingDeferChild()
            }
            while !taskGroupThrowingDeferChildStarted {
                await Task.yield()
            }
            defer {
                taskGroupThrowingDeferEvents.append("defer")
            }
            taskGroupThrowingDeferEvents.append("body-throw")
            throw TaskGroupThrowingDeferCleanupError.failed
        }
        taskGroupThrowingDeferEvents.append("missed")
    } catch TaskGroupThrowingDeferCleanupError.failed {
        taskGroupThrowingDeferEvents.append("caught-body")
    } catch {
        taskGroupThrowingDeferEvents.append("wrong-error")
    }
    return taskGroupThrowingDeferEvents.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingDeferCleanupOrderProbe()
}
