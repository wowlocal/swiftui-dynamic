@MainActor
final class TaskPriorityTransitiveRecorder {
    var bottomBefore = -1
    var bottomAfter = -1
    var middleAfter = -1
    var bottomStarted = false
    var middleWaiting = false
    var releaseBottom = false
    var finished = false
    var bottomTask: Task<Int, Never>?
    var middleTask: Task<Int, Never>?
    var highTask: Task<Int, Never>?
}

@MainActor
func startTaskPriorityTransitiveProbe() -> TaskPriorityTransitiveRecorder {
    let recorder = TaskPriorityTransitiveRecorder()
    let bottom = Task(priority: .background) {
        recorder.bottomBefore = Int(Task.currentPriority.rawValue)
        recorder.bottomStarted = true
        while !recorder.releaseBottom {
            _ = await parityYield("waiting-for-transitive-waiter")
        }
        recorder.bottomAfter = Int(Task.currentPriority.rawValue)
        return recorder.bottomAfter
    }
    recorder.bottomTask = bottom

    Task {
        while !recorder.bottomStarted {
            _ = await parityYield("waiting-for-bottom-task")
        }
        let middle = Task(priority: .utility) {
            recorder.middleWaiting = true
            let value = await bottom.value
            recorder.middleAfter = Int(Task.currentPriority.rawValue)
            return value
        }
        recorder.middleTask = middle
        while !recorder.middleWaiting {
            _ = await parityYield("waiting-for-middle-waiter")
        }
        let high = Task(priority: .high) {
            recorder.releaseBottom = true
            return await middle.value
        }
        recorder.highTask = high
        _ = await high.value
        recorder.finished = true
    }
    return recorder
}

@MainActor
func taskPriorityTransitiveProbe() async -> String {
    let recorder = startTaskPriorityTransitiveProbe()
    while !recorder.finished {
        _ = await parityYield("waiting-for-transitive-probe")
    }
    return "\(recorder.bottomBefore),\(recorder.bottomAfter),\(recorder.middleAfter)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskPriorityTransitiveProbe()
}
