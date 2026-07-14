@MainActor
final class TaskGroupNestedRecorder {
    var events: [String] = []
}

@MainActor
func recordTaskGroupNestedEvent(
    _ event: String,
    in recorder: TaskGroupNestedRecorder
) {
    recorder.events.append(event)
}

@MainActor
func openTaskGroupNestedGrandchild(
    _ recorder: TaskGroupNestedRecorder
) {
    recorder.events.append("inner-open")
    parityOpenTaskValueGate()
}

@MainActor
func taskGroupNestedGrandchild(
    _ recorder: TaskGroupNestedRecorder
) async -> String {
    recorder.events.append("grandchild-start")
    await parityWaitTaskValueGate()
    recorder.events.append("grandchild-end")
    return "value"
}

@MainActor
func taskGroupChildNestedGroupProbe() async -> String {
    let recorder = TaskGroupNestedRecorder()
    let value = await withTaskGroup(of: String.self) { outerGroup in
        outerGroup.addTask {
            let innerValue = await withTaskGroup(
                of: String.self
            ) { innerGroup in
                innerGroup.addTask {
                    await taskGroupNestedGrandchild(recorder)
                }
                await parityAwaitTaskValueGateStarted()
                await openTaskGroupNestedGrandchild(recorder)
                return await innerGroup.next() ?? "inner-missing"
            }
            await recordTaskGroupNestedEvent("inner-finished", in: recorder)
            return innerValue
        }
        let outerValue = await outerGroup.next() ?? "outer-missing"
        recorder.events.append("outer-finished")
        return outerValue
    }
    return recorder.events.joined(separator: ",") + ":" + value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupChildNestedGroupProbe()
}
