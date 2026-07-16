enum TaskPriorityEscalationHandlerProbeError: Error {
    case expected
}

nonisolated func taskPriorityEscalationExpectedFailure()
    async throws(TaskPriorityEscalationHandlerProbeError) -> Int
{
    throw TaskPriorityEscalationHandlerProbeError.expected
}

@MainActor
final class TaskPriorityEscalationHandlerRecorder {
    var activeStarted = false
    var activeRelease = false
    var activeScopeExited = false
    var activePostRelease = false
    var activeFinished = false
    var activeScopedPriority = -1
    var activePriority = -1
    var activeTask: Task<Int, Never>?
    var activeWaiter: Task<Int, Never>?
    var activeFinalWaiter: Task<Int, Never>?

    var errorReady = false
    var errorRelease = false
    var errorFinished = false
    var exactError = false
    var errorPriority = -1
    var errorTask: Task<Int, Never>?
    var errorWaiter: Task<Int, Never>?

    var cancellationStarted = false
    var cancellationReady = false
    var cancellationRelease = false
    var cancellationFinished = false
    var exactCancellation = false
    var cancellationPriority = -1
    var cancellationTask: Task<Int, Never>?
    var cancellationWaiter: Task<Int, Never>?

    var replayBeforeScope = false
    var replayEnterScope = false
    var replayScopeEntered = false
    var replaySecondRelease = false
    var replayFinished = false
    var replayWasNotDelivered = false
    var replayPriority = -1
    var replayTask: Task<Int, Never>?
    var replayFirstWaiter: Task<Int, Never>?
    var replayFinalWaiter: Task<Int, Never>?
}

@MainActor
func startTaskPriorityEscalationHandlerProbe()
    -> TaskPriorityEscalationHandlerRecorder
{
    let recorder = TaskPriorityEscalationHandlerRecorder()

    let active = Task(priority: .background) {
        let value = await withTaskPriorityEscalationHandler(operation: {
            await withTaskPriorityEscalationHandler(operation: {
                recorder.activeStarted = true
                while !recorder.activeRelease {
                    _ = await parityYield("waiting-for-active-waiter")
                }
                while !parityPriorityEscalationEvents().contains("inner:")
                    || !parityPriorityEscalationEvents().contains("outer:")
                {
                    _ = await parityYield("waiting-for-active-handlers")
                }
                return Int(Task.currentPriority.rawValue)
            }, onPriorityEscalated: { oldPriority, newPriority in
                parityRecordPriorityEscalationEvent(
                    "inner:\(oldPriority.rawValue)>\(newPriority.rawValue)")
            })
        }, onPriorityEscalated: { oldPriority, newPriority in
            parityRecordPriorityEscalationEvent(
                "outer:\(oldPriority.rawValue)>\(newPriority.rawValue)")
        })
        recorder.activeScopedPriority = value
        recorder.activeScopeExited = true
        while !recorder.activePostRelease {
            _ = await parityYield("waiting-after-active-scope")
        }
        recorder.activePriority = Int(Task.currentPriority.rawValue)
        return recorder.activePriority
    }
    recorder.activeTask = active

    Task {
        while !recorder.activeStarted {
            _ = await parityYield("waiting-for-active-operation")
        }
        let firstWaiter = Task(priority: .low) {
            recorder.activeRelease = true
            return await active.value
        }
        recorder.activeWaiter = firstWaiter
        while !recorder.activeScopeExited {
            _ = await parityYield("waiting-for-active-scope-exit")
        }
        let finalWaiter = Task(priority: .high) {
            recorder.activePostRelease = true
            return await active.value
        }
        recorder.activeFinalWaiter = finalWaiter
        _ = await finalWaiter.value
        _ = await firstWaiter.value
        recorder.activeFinished = true
    }

    let throwing = Task(priority: .background) {
        do {
            let _: Int = try await
                _isolatedParameter_withTaskPriorityEscalationHandler(
                    operation: taskPriorityEscalationExpectedFailure,
                    onPriorityEscalated: { oldPriority, newPriority in
                        parityRecordPriorityEscalationEvent(
                            "late-error:\(oldPriority.rawValue)>\(newPriority.rawValue)")
                    },
                    isolation: nil)
        } catch TaskPriorityEscalationHandlerProbeError.expected {
            recorder.exactError = true
        } catch {
            recorder.exactError = false
        }
        recorder.errorReady = true
        while !recorder.errorRelease {
            _ = await parityYield("waiting-for-error-waiter")
        }
        recorder.errorPriority = Int(Task.currentPriority.rawValue)
        return recorder.errorPriority
    }
    recorder.errorTask = throwing

    Task {
        while !recorder.errorReady {
            _ = await parityYield("waiting-for-error-scope-exit")
        }
        let waiter = Task(priority: .high) {
            recorder.errorRelease = true
            return await throwing.value
        }
        recorder.errorWaiter = waiter
        _ = await waiter.value
        recorder.errorFinished = true
    }

    let cancelled = Task(priority: .background) {
        do {
            let _: Int = try await withTaskPriorityEscalationHandler(
                operation: {
                    recorder.cancellationStarted = true
                    while true {
                        try Task.checkCancellation()
                        _ = await parityYield("waiting-for-cancellation")
                    }
                },
                onPriorityEscalated: { oldPriority, newPriority in
                    parityRecordPriorityEscalationEvent(
                        "late-cancellation:\(oldPriority.rawValue)>\(newPriority.rawValue)")
                })
        } catch is CancellationError {
            recorder.exactCancellation = true
        } catch {
            recorder.exactCancellation = false
        }
        recorder.cancellationReady = true
        while !recorder.cancellationRelease {
            _ = await parityYield("waiting-for-cancellation-waiter")
        }
        recorder.cancellationPriority = Int(Task.currentPriority.rawValue)
        return recorder.cancellationPriority
    }
    recorder.cancellationTask = cancelled

    Task {
        while !recorder.cancellationStarted {
            _ = await parityYield("waiting-for-cancellation-operation")
        }
        cancelled.cancel()
        while !recorder.cancellationReady {
            _ = await parityYield("waiting-for-cancellation-scope-exit")
        }
        let waiter = Task(priority: .high) {
            recorder.cancellationRelease = true
            return await cancelled.value
        }
        recorder.cancellationWaiter = waiter
        _ = await waiter.value
        recorder.cancellationFinished = true
    }

    let replay = Task(priority: .background) {
        recorder.replayBeforeScope = true
        while !recorder.replayEnterScope {
            _ = await parityYield("waiting-for-prior-escalation")
        }
        let value = await withTaskPriorityEscalationHandler(operation: {
            recorder.replayScopeEntered = true
            recorder.replayWasNotDelivered =
                !parityPriorityEscalationEvents().contains("replay:")
            while !recorder.replaySecondRelease {
                _ = await parityYield("waiting-for-second-escalation")
            }
            while !parityPriorityEscalationEvents().contains("replay:") {
                _ = await parityYield("waiting-for-replay-handler")
            }
            return Int(Task.currentPriority.rawValue)
        }, onPriorityEscalated: { oldPriority, newPriority in
            parityRecordPriorityEscalationEvent(
                "replay:\(oldPriority.rawValue)>\(newPriority.rawValue)")
        })
        recorder.replayPriority = value
        return value
    }
    recorder.replayTask = replay

    Task {
        while !recorder.replayBeforeScope {
            _ = await parityYield("waiting-for-replay-task")
        }
        let firstWaiter = Task(priority: .low) {
            recorder.replayEnterScope = true
            return await replay.value
        }
        recorder.replayFirstWaiter = firstWaiter
        while !recorder.replayScopeEntered {
            _ = await parityYield("waiting-for-replay-scope")
        }
        let finalWaiter = Task(priority: .high) {
            recorder.replaySecondRelease = true
            return await replay.value
        }
        recorder.replayFinalWaiter = finalWaiter
        _ = await finalWaiter.value
        _ = await firstWaiter.value
        recorder.replayFinished = true
    }

    return recorder
}

@MainActor
func taskPriorityEscalationHandlerProbe() async -> String {
    let recorder = startTaskPriorityEscalationHandlerProbe()
    while !recorder.activeFinished || !recorder.errorFinished
        || !recorder.cancellationFinished || !recorder.replayFinished
    {
        _ = await parityYield("waiting-for-priority-handler-probe")
    }
    return "active:\(recorder.activeScopedPriority):\(recorder.activePriority)"
        + "|error:\(recorder.exactError):\(recorder.errorPriority)"
        + "|cancel:\(recorder.exactCancellation):\(recorder.cancellationPriority)"
        + "|replay:\(recorder.replayWasNotDelivered):\(recorder.replayPriority)"
        + "|events:\(parityPriorityEscalationEvents())"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskPriorityEscalationHandlerProbe()
}
