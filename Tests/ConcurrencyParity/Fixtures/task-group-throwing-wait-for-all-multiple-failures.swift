enum ThrowingTaskGroupMultipleFailure: Error {
    case first
    case second
}

@MainActor
var taskGroupMultipleFailureCompletionCount = 0

@MainActor
func recordTaskGroupMultipleFailureCompletion() {
    taskGroupMultipleFailureCompletionCount += 1
}

@MainActor
func taskGroupThrowingWaitForAllMultipleFailuresProbe() async -> String {
    let opener = Task {
        await parityAwaitTaskValueGateStarted()
        parityOpenTaskValueGate()
    }

    do {
        _ = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await parityWaitTaskValueGate()
                await recordTaskGroupMultipleFailureCompletion()
                throw ThrowingTaskGroupMultipleFailure.first
            }
            group.addTask {
                await recordTaskGroupMultipleFailureCompletion()
                throw ThrowingTaskGroupMultipleFailure.second
            }
            try await group.waitForAll()
            return "missed"
        }
        opener.cancel()
        return "missed"
    } catch {
        _ = await opener.result
        let drained = taskGroupMultipleFailureCompletionCount == 2
            ? "drained"
            : "not-drained"
        switch error {
        case ThrowingTaskGroupMultipleFailure.first:
            return "caught-first:" + drained
        case ThrowingTaskGroupMultipleFailure.second:
            return "caught-second:" + drained
        default:
            return "wrong-error:" + drained
        }
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingWaitForAllMultipleFailuresProbe()
}
