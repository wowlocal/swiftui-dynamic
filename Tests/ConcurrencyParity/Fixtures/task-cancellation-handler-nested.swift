@MainActor
final class NestedCancellationHandlerState {
    var started = false
    nonisolated(unsafe) var events: [String] = []
}

@MainActor
func nestedCancellationHandlerProbe() async -> String {
    let state = NestedCancellationHandlerState()
    let worker = Task {
        await withTaskCancellationHandler(operation: {
            await withTaskCancellationHandler(operation: {
                state.started = true
                while !Task.isCancelled {
                    await Task.yield()
                }
                state.events.append("operation")
            }, onCancel: {
                state.events.append("inner")
            })
        }, onCancel: {
            state.events.append("outer")
        })
    }

    while !state.started {
        await Task.yield()
    }
    worker.cancel()
    worker.cancel()
    await worker.value
    return state.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await nestedCancellationHandlerProbe()
}
