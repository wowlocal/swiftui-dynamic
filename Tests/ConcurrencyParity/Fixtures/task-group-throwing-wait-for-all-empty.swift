@MainActor
func taskGroupThrowingWaitForAllEmptyProbe() async -> String {
    do {
        return try await withThrowingTaskGroup(of: String.self) { group in
            try await group.waitForAll()
            return "empty"
        }
    } catch {
        return "error:" + "\(error)"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingWaitForAllEmptyProbe()
}
