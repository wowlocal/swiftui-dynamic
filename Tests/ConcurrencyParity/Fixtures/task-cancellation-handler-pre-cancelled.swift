@MainActor
final class PreCancelledHandlerState {
    nonisolated(unsafe) var handlerCount = 0
    nonisolated(unsafe) var handlerObservedCancellation = false
    var operationObservedHandler = false
    var task: Task<String, Never>?
}

@MainActor
func startPreCancelledHandlerProbe() -> PreCancelledHandlerState {
    let state = PreCancelledHandlerState()
    let task = Task {
        await withTaskCancellationHandler(operation: {
            state.operationObservedHandler = state.handlerCount == 1
            return Task.isCancelled
                ? "operation-cancelled" : "operation-active"
        }, onCancel: {
            state.handlerCount += 1
            state.handlerObservedCancellation = Task.isCancelled
        })
    }
    state.task = task
    task.cancel()
    task.cancel()
    return state
}

@MainActor
func preCancelledHandlerProbe() async -> String {
    let state = startPreCancelledHandlerProbe()
    let result = await state.task!.value
    return "\(state.handlerCount),\(state.handlerObservedCancellation),"
        + "\(state.operationObservedHandler),\(result)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await preCancelledHandlerProbe()
}
