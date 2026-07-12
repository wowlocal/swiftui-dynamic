@MainActor
final class TaskValueRecorder {
    var events: [String] = []
}

@MainActor
func taskValueSuccessProbe() async -> String {
    let recorder = TaskValueRecorder()
    let handle = Task {
        recorder.events.append("child-start")
        await parityWaitTaskValueGate()
        recorder.events.append("child-end")
        return "value"
    }
    await parityAwaitTaskValueGateStarted()
    recorder.events.append("before-value")
    Task {
        parityOpenTaskValueGate()
    }
    let value = await handle.value
    recorder.events.append(value)
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskValueSuccessProbe()
}
