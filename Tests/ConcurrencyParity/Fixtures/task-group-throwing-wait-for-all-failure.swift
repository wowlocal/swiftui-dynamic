enum ThrowingTaskGroupWaitFailure: Error {
    case failed
}

@MainActor
func taskGroupThrowingWaitForAllFailureProbe() async -> String {
    do {
        let success = try await withThrowingTaskGroup(
            of: String.self
        ) { group in
            group.addTask {
                return "value"
            }
            try await group.waitForAll()
            return "success"
        }

        do {
            _ = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    throw ThrowingTaskGroupWaitFailure.failed
                }
                try await group.waitForAll()
                return "missed"
            }
            return success + ":missed"
        } catch {
            switch error {
            case ThrowingTaskGroupWaitFailure.failed:
                return success + ":caught-child"
            default:
                return success + ":wrong-error"
            }
        }
    } catch {
        return "wrong-success:" + "\(error)"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingWaitForAllFailureProbe()
}
