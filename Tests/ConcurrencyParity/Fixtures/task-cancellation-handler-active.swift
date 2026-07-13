@MainActor
final class TaskCancellationHandlerState {
    var started = false
    nonisolated(unsafe) var handlerCount = 0
    nonisolated(unsafe) var handlerObservedCancellation = false
    var operationObservedHandler = false
}

@MainActor
func taskCancellationHandlerActiveProbe() async -> String {
    let state = TaskCancellationHandlerState()
    let worker = Task {
        await withTaskCancellationHandler(operation: {
            state.started = true
            while !Task.isCancelled {
                await Task.yield()
            }
            state.operationObservedHandler = state.handlerCount == 1
            return "done"
        }, onCancel: {
            state.handlerCount += 1
            state.handlerObservedCancellation = Task.isCancelled
        })
    }

    while !state.started {
        await Task.yield()
    }
    let beforeCancel = state.handlerCount
    worker.cancel()
    let afterCancel = state.handlerCount
    worker.cancel()
    let afterSecondCancel = state.handlerCount
    let result = await worker.value
    return "\(beforeCancel),\(afterCancel),\(afterSecondCancel),"
        + "\(state.handlerObservedCancellation),"
        + "\(state.operationObservedHandler),\(result)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskCancellationHandlerActiveProbe()
}
