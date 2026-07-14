@MainActor
final class TaskGroupCancelAllRecorder {
    var events: [String] = []
}

@MainActor
func taskGroupCancelAllChild(
    _ recorder: TaskGroupCancelAllRecorder
) async -> String {
    recorder.events.append("child-start")
    do {
        try await parityWaitForever()
        recorder.events.append("child-wrong-finish")
    } catch is CancellationError {
        recorder.events.append("child-cancelled")
    } catch {
        recorder.events.append("child-wrong-error")
    }
    recorder.events.append("child-finished")
    return "value"
}

@MainActor
func taskGroupCancelAllProbe() async -> String {
    let recorder = TaskGroupCancelAllRecorder()
    await withTaskGroup(of: String.self) { group in
        group.addTask {
            await taskGroupCancelAllChild(recorder)
        }
        await parityAwaitWaitStarted()
        recorder.events.append("cancel-all")
        group.cancelAll()
        await group.waitForAll()
        recorder.events.append("group-finished")
    }
    recorder.events.append("after-scope")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupCancelAllProbe()
}
