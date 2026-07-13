@MainActor
final class TaskPriorityEscalationRecorder {
    var before = -1
    var after = -1
    var inherited = -1
    var lowStarted = false
    var releaseLow = false
    var finished = false
    var lowTask: Task<Int, Never>?
    var highTask: Task<Int, Never>?
    var inheritedTask: Task<Int, Never>?
}

@MainActor
func startTaskPriorityEscalationProbe() -> TaskPriorityEscalationRecorder {
    let recorder = TaskPriorityEscalationRecorder()
    let low = Task(priority: .background) {
        recorder.before = Int(Task.currentPriority.rawValue)
        recorder.lowStarted = true
        while !recorder.releaseLow {
            _ = await parityYield("waiting-for-high-priority-waiter")
        }
        recorder.after = Int(Task.currentPriority.rawValue)
        let child = Task {
            Int(Task.currentPriority.rawValue)
        }
        recorder.inheritedTask = child
        recorder.inherited = await child.value
        return recorder.after
    }
    recorder.lowTask = low

    Task {
        while !recorder.lowStarted {
            _ = await parityYield("waiting-for-low-priority-task")
        }
        let high = Task(priority: .high) {
            recorder.releaseLow = true
            return await low.value
        }
        recorder.highTask = high
        _ = await high.value
        recorder.finished = true
    }
    return recorder
}

@MainActor
func taskPriorityEscalationProbe() async -> String {
    let recorder = startTaskPriorityEscalationProbe()
    while !recorder.finished {
        _ = await parityYield("waiting-for-priority-probe")
    }
    return "\(recorder.before),\(recorder.after),\(recorder.inherited)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskPriorityEscalationProbe()
}
