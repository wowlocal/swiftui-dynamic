@MainActor
final class TaskValueWaiterCancellationRecorder {
    var targetStarted = false
    var waiterStarted = false
    var releaseTarget = false
    var finished = false
    var handleWasCancelled = false
    var result = ""
    var target: Task<String, Never>?
    var waiter: Task<String, Never>?
}

@MainActor
func startTaskValueWaiterCancellationProbe()
    -> TaskValueWaiterCancellationRecorder {
    let recorder = TaskValueWaiterCancellationRecorder()
    let target = Task {
        recorder.targetStarted = true
        while !recorder.releaseTarget {
            _ = await parityYield("waiting-for-cancelled-value-waiter")
        }
        return Task.isCancelled ? "target-cancelled" : "target-active"
    }
    recorder.target = target

    Task {
        while !recorder.targetStarted {
            _ = await parityYield("waiting-for-value-target")
        }
        let waiter = Task {
            recorder.waiterStarted = true
            let targetState = await target.value
            let waiterState = Task.isCancelled
                ? "waiter-cancelled" : "waiter-active"
            return targetState + "," + waiterState
        }
        recorder.waiter = waiter
        while !recorder.waiterStarted {
            _ = await parityYield("waiting-for-value-waiter")
        }

        // On MainActor the waiter has no suspension between setting the flag
        // and awaiting target.value. The controller can resume here only
        // after that value wait has been registered.
        waiter.cancel()
        recorder.handleWasCancelled = waiter.isCancelled
        recorder.releaseTarget = true
        recorder.result = await waiter.value
        recorder.finished = true
    }
    return recorder
}

@MainActor
func taskValueWaiterCancellationProbe() async -> String {
    let recorder = startTaskValueWaiterCancellationProbe()
    while !recorder.finished {
        _ = await parityYield("waiting-for-waiter-cancellation-probe")
    }
    let handleState = recorder.handleWasCancelled
        ? "handle-cancelled" : "handle-active"
    return recorder.result + "," + handleState
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskValueWaiterCancellationProbe()
}
