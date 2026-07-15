@MainActor
final class TaskGroupChildUnstructuredRecorder {
    var events: [String] = []
}

@MainActor
func taskGroupChildUnstructuredOperation(
    _ recorder: TaskGroupChildUnstructuredRecorder
) async -> String {
    recorder.events.append("task-start")
    await parityWaitTaskValueGate()
    recorder.events.append(Task.isCancelled ? "task-cancelled" : "task-active")
    return "value"
}

@MainActor
func taskGroupChildCreateUnstructuredTask(
    _ recorder: TaskGroupChildUnstructuredRecorder
) async -> Task<String, Never> {
    recorder.events.append("group-child-start")
    let task = Task {
        await taskGroupChildUnstructuredOperation(recorder)
    }
    await parityAwaitTaskValueGateStarted()
    recorder.events.append("group-child-return")
    return task
}

@MainActor
func taskGroupChildUnstructuredTaskProbe() async -> String {
    let recorder = TaskGroupChildUnstructuredRecorder()
    let task = await withTaskGroup(of: Task<String, Never>.self) { group in
        group.addTask {
            await taskGroupChildCreateUnstructuredTask(recorder)
        }
        let task = await group.next()!
        recorder.events.append("group-finished")
        return task
    }

    recorder.events.append("after-scope")
    let state = task.isCancelled ? "cancelled" : "active"
    parityOpenTaskValueGate()
    let value = await task.value
    return recorder.events.joined(separator: ",") + ":" + state + ":" + value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupChildUnstructuredTaskProbe()
}
