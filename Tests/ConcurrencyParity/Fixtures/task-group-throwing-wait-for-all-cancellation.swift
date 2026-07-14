@MainActor
var taskGroupThrowingWaitCancellationCompletionCount = 0

@MainActor
func recordTaskGroupThrowingWaitCancellationCompletion() {
    taskGroupThrowingWaitCancellationCompletionCount += 1
}

@MainActor
func taskGroupThrowingWaitForAllCancellationProbe() async -> String {
    do {
        _ = try await withThrowingTaskGroup(of: String.self) { group in
            group.cancelAll()
            group.addTask {
                await recordTaskGroupThrowingWaitCancellationCompletion()
                try Task.checkCancellation()
                return "missed"
            }
            group.addTask {
                await recordTaskGroupThrowingWaitCancellationCompletion()
                return "success"
            }
            try await group.waitForAll()
            return "missed"
        }
        return "missed"
    } catch {
        let errorKind = type(of: error) == CancellationError.self
            ? "cancellation"
            : "wrong-error"
        let ownerState = Task.isCancelled ? "owner-cancelled" : "owner-active"
        let drained = taskGroupThrowingWaitCancellationCompletionCount == 2
            ? "drained"
            : "not-drained"
        return errorKind + ":" + ownerState + ":" + drained
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingWaitForAllCancellationProbe()
}
