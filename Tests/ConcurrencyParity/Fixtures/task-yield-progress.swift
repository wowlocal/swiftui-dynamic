@MainActor
final class TaskYieldProgressState {
    var workerRan = false
}

@MainActor
func taskYieldProgressProbe() async -> String {
    let state = TaskYieldProgressState()
    let worker = Task {
        state.workerRan = true
    }

    while !state.workerRan {
        await Task.yield()
    }
    await worker.value
    return "completed"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskYieldProgressProbe()
}
