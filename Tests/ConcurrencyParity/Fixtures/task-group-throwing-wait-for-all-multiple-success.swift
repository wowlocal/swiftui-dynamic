@MainActor
func taskGroupThrowingWaitForAllMultipleSuccessProbe() async -> String {
    do {
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                return "first"
            }
            group.addTask {
                return "second"
            }
            try await group.waitForAll()
            return "all-success"
        }
    } catch {
        return "error:" + "\(error)"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingWaitForAllMultipleSuccessProbe()
}
