@MainActor
final class TaskGroupWaitForAllRecorder {
    var events: [String] = []
}

@MainActor
func taskGroupWaitForAllChild(
    _ recorder: TaskGroupWaitForAllRecorder
) async -> String {
    recorder.events.append("child-start")
    await parityWaitTaskValueGate()
    recorder.events.append("child-end")
    return "value"
}

@MainActor
func taskGroupWaitForAllProbe() async -> String {
    let recorder = TaskGroupWaitForAllRecorder()
    await withTaskGroup(of: String.self) { group in
        group.addTask {
            await taskGroupWaitForAllChild(recorder)
        }
        await parityAwaitTaskValueGateStarted()
        recorder.events.append("parent-open")
        parityOpenTaskValueGate()
        await group.waitForAll()
        recorder.events.append("group-finished")
    }
    recorder.events.append("after-scope")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupWaitForAllProbe()
}
