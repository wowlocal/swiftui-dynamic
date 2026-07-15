@MainActor
final class TaskCancellationHandlerState {
    var started = false
    nonisolated(unsafe) var handlerCount = 0
    nonisolated(unsafe) var handlerObservedCancellation = false
    var operationObservedHandler = false
}

final class DeprecatedTaskCancellationHandlerState: @unchecked Sendable {
    nonisolated(unsafe) var handlerCount = 0
    nonisolated(unsafe) var handlerObservedCancellation = false
}

@MainActor
func modernTaskCancellationHandlerActiveProbe() async -> String {
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

func deprecatedTaskCancellationHandlerActiveProbe() async -> String {
    let state = DeprecatedTaskCancellationHandlerState()
    let worker = Task {
        await withTaskCancellationHandler(handler: {
            state.handlerCount += 1
            state.handlerObservedCancellation = Task.isCancelled
        }, operation: {
            do {
                try await parityWaitForever()
            } catch {
                // Cancellation wakes the controlled native/interpreter gate.
            }
            return "done"
        })
    }

    await parityAwaitWaitStarted()
    let beforeCancel = state.handlerCount
    worker.cancel()
    let afterCancel = state.handlerCount
    worker.cancel()
    let afterSecondCancel = state.handlerCount
    let result = await worker.value
    return "\(beforeCancel),\(afterCancel),\(afterSecondCancel),"
        + "\(state.handlerObservedCancellation),\(result)"
}

@MainActor
func taskCancellationHandlerActiveProbe() async -> String {
    let deprecated = await deprecatedTaskCancellationHandlerActiveProbe()
    let modern = await modernTaskCancellationHandlerActiveProbe()
    return "deprecated[\(deprecated)]|modern[\(modern)]"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskCancellationHandlerActiveProbe()
}
