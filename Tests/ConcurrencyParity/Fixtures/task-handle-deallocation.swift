@MainActor
final class TaskHandleDeallocationRecorder {
    var started = false
    var release = false
    var finished = false
    var result = ""
}

@MainActor
func startTaskHandleDeallocationProbe()
    -> TaskHandleDeallocationRecorder {
    let recorder = TaskHandleDeallocationRecorder()

    // No source-level handle survives this statement. The runtime task must
    // retain its operation independently until that operation completes.
    _ = Task {
        recorder.started = true
        while !recorder.release {
            _ = await parityYield("waiting-after-handle-drop")
        }
        let cancellationState = Task.isCancelled
            ? "cancelled" : "active"
        recorder.result = "completed," + cancellationState
        recorder.finished = true
    }
    return recorder
}

@MainActor
func taskHandleDeallocationProbe() async -> String {
    let recorder = startTaskHandleDeallocationProbe()
    while !recorder.started {
        _ = await parityYield("waiting-for-dropped-handle-task")
    }
    recorder.release = true
    while !recorder.finished {
        _ = await parityYield("waiting-for-dropped-handle-completion")
    }
    return recorder.result
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskHandleDeallocationProbe()
}
