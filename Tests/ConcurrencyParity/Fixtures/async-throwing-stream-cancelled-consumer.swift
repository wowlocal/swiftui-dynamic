final class AsyncThrowingStreamCancellationState: @unchecked Sendable {
    var enteredNext = false
    var termination = "none"
}

@MainActor
func asyncThrowingStreamCancelledConsumerProbe() async -> String {
    let state = AsyncThrowingStreamCancellationState()
    let stream = AsyncThrowingStream<Int, Error> { continuation in
        continuation.onTermination = { termination in
            state.termination = "\(termination)"
        }
    }
    let consumer = Task { @MainActor in
        var iterator = stream.makeAsyncIterator()
        state.enteredNext = true
        let value = try? await iterator.next()
        return "\(value == nil):\(Task.isCancelled):\(state.termination)"
    }

    while !state.enteredNext {
        await Task.yield()
    }
    consumer.cancel()
    return "\(await consumer.value):\(state.termination)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamCancelledConsumerProbe()
}
