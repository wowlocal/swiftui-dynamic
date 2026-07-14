@MainActor
func taskGroupAddAfterCancelAllChild() async -> String {
    if Task.isCancelled {
        return "cancelled"
    }
    return "active"
}

@MainActor
func taskGroupAddAfterCancelAllProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        group.cancelAll()
        group.addTask {
            await taskGroupAddAfterCancelAllChild()
        }
        return await group.next() ?? "empty"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupAddAfterCancelAllProbe()
}
