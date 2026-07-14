import Foundation

@MainActor
var taskGroupOwnerDeferEvents: [String] = []

@MainActor
var taskGroupOwnerDeferChildStarted = false

@MainActor
var taskGroupOwnerDeferReady = false

@MainActor
var taskGroupOwnerDeferReleaseChild = false

@MainActor
func taskGroupOwnerDeferChild() async -> String {
    taskGroupOwnerDeferChildStarted = true
    taskGroupOwnerDeferEvents.append("child-start")
    do {
        try await Task.sleep(for: .seconds(30))
    } catch {}
    while !taskGroupOwnerDeferReleaseChild {
        await Task.yield()
    }
    let state = Task.isCancelled ? "child-cancelled" : "child-active"
    taskGroupOwnerDeferEvents.append(state)
    return state
}

@MainActor
func taskGroupOwnerDeferBody() async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask {
            await taskGroupOwnerDeferChild()
        }
        while !taskGroupOwnerDeferChildStarted {
            await Task.yield()
        }
        taskGroupOwnerDeferReady = true
        while !Task.isCancelled {
            await Task.yield()
        }
        defer {
            taskGroupOwnerDeferEvents.append("defer")
            taskGroupOwnerDeferReleaseChild = true
        }
        taskGroupOwnerDeferEvents.append("scope-exit")
    }
    return taskGroupOwnerDeferEvents.joined(separator: ",")
}

@MainActor
func taskGroupOwnerCancellationDeferCleanupOrderProbe() async -> String {
    taskGroupOwnerDeferEvents = []
    taskGroupOwnerDeferChildStarted = false
    taskGroupOwnerDeferReady = false
    taskGroupOwnerDeferReleaseChild = false

    let owner = Task {
        await taskGroupOwnerDeferBody()
    }
    while !taskGroupOwnerDeferReady {
        await Task.yield()
    }
    owner.cancel()
    let value = await owner.value
    let ownerState = owner.isCancelled ? "cancelled" : "active"
    return value + ",returned:" + ownerState
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupOwnerCancellationDeferCleanupOrderProbe()
}
