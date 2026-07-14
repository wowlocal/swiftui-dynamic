@MainActor
final class TaskGroupImplicitScopeExitRecorder {
    var events: [String] = []
}

@MainActor
func taskGroupImplicitScopeExitChild(
    _ recorder: TaskGroupImplicitScopeExitRecorder
) async -> String {
    recorder.events.append("child-start")
    await parityWaitTaskValueGate()
    recorder.events.append("child-end")
    return "value"
}

@MainActor
func taskGroupImplicitScopeExitProbe() async -> String {
    let recorder = TaskGroupImplicitScopeExitRecorder()
    await withTaskGroup(of: String.self) { group in
        group.addTask {
            await taskGroupImplicitScopeExitChild(recorder)
        }
        await parityAwaitTaskValueGateStarted()
        recorder.events.append("body-return")
        parityOpenTaskValueGate()
    }
    recorder.events.append("after-scope")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupImplicitScopeExitProbe()
}
