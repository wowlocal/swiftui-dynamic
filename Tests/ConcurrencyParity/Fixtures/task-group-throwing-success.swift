@MainActor
func taskGroupThrowingSuccessProbe() async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            return "value"
        }
        return try await group.next() ?? "empty"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await taskGroupThrowingSuccessProbe()
}
