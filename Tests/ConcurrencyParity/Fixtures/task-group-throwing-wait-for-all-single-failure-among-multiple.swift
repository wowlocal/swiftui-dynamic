enum ThrowingTaskGroupSingleFailure: Error {
    case failed
}

@MainActor
func taskGroupThrowingWaitForAllSingleFailureProbe() async -> String {
    do {
        _ = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                return "value"
            }
            group.addTask {
                throw ThrowingTaskGroupSingleFailure.failed
            }
            try await group.waitForAll()
            return "missed"
        }
        return "missed"
    } catch {
        switch error {
        case ThrowingTaskGroupSingleFailure.failed:
            return "caught-child"
        default:
            return "wrong-error"
        }
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingWaitForAllSingleFailureProbe()
}
