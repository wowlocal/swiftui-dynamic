enum ThrowingTaskGroupNextFailure: Error {
    case failed
}

@MainActor
func taskGroupThrowingNextFailureProbe() async -> String {
    do {
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                throw ThrowingTaskGroupNextFailure.failed
            }
            _ = try await group.next()
            return "missed"
        }
    } catch {
        switch error {
        case ThrowingTaskGroupNextFailure.failed:
            return "caught-child"
        default:
            return "wrong-error"
        }
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingNextFailureProbe()
}
