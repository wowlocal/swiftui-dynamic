@MainActor
final class TaskCancellationBeforeStartRecorder {
    var bodyStarted = false
    var bodyState = ""
    var handleWasCancelled = false
    var task: Task<String, Never>?
}

@MainActor
func startTaskCancellationBeforeStartProbe()
    -> TaskCancellationBeforeStartRecorder {
    let recorder = TaskCancellationBeforeStartRecorder()
    let task = Task {
        recorder.bodyStarted = true
        let state = Task.isCancelled ? "body-cancelled" : "body-active"
        recorder.bodyState = state
        return state
    }
    recorder.task = task

    // The inherited MainActor task cannot start before this function reaches
    // its first suspension, so this request deterministically precedes entry.
    task.cancel()
    recorder.handleWasCancelled = task.isCancelled
    return recorder
}

@MainActor
func taskCancellationBeforeStartProbe() async -> String {
    let recorder = startTaskCancellationBeforeStartProbe()
    let value = await recorder.task!.value
    let handleState = recorder.handleWasCancelled
        ? "handle-cancelled" : "handle-active"
    let startState = recorder.bodyStarted ? "body-ran" : "body-skipped"
    return startState + "," + value + "," + handleState
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskCancellationBeforeStartProbe()
}
