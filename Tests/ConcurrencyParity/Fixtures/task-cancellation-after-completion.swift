@MainActor
func taskCancellationAfterCompletionProbe() async -> String {
    let task = Task {
        "value"
    }

    // The first read proves that the task is terminal before cancel() runs.
    let firstValue = await task.value
    let before = task.isCancelled ? "cancelled" : "active"
    task.cancel()
    let after = task.isCancelled ? "cancelled" : "active"
    let secondValue = await task.value
    return before + "," + after + "," + firstValue + "," + secondValue
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskCancellationAfterCompletionProbe()
}
