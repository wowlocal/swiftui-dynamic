@MainActor
final class TaskPriorityRecorder {
    var parent = -1
    var child = -1
    var detached = -1
    var finished = false
    var parentTask: Task<Void, Never>?
    var childTask: Task<Int, Never>?
    var detachedTask: Task<Int, Never>?
}

@MainActor
func startTaskPriorityInheritanceProbe() -> TaskPriorityRecorder {
    let recorder = TaskPriorityRecorder()
    recorder.parentTask = Task(priority: .utility) {
        recorder.parent = Int(Task.currentPriority.rawValue)
        let child = Task {
            Int(Task.currentPriority.rawValue)
        }
        let detached = Task.detached {
            Int(Task.currentPriority.rawValue)
        }
        recorder.childTask = child
        recorder.detachedTask = detached
        recorder.child = await child.value
        recorder.detached = await detached.value
        recorder.finished = true
    }
    return recorder
}

@MainActor
func taskPriorityInheritanceProbe() async -> String {
    let recorder = startTaskPriorityInheritanceProbe()
    while !recorder.finished {
        _ = await parityYield("")
    }
    return "\(recorder.parent),\(recorder.child),\(recorder.detached)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskPriorityInheritanceProbe()
}
