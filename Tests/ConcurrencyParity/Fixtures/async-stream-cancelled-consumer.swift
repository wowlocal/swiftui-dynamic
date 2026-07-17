final class AsyncStreamCancellationProbeState: @unchecked Sendable {
    var enteredNext = false
    var termination = "none"
}

@MainActor
func asyncStreamCancelledConsumerProbe() async -> String {
    let state = AsyncStreamCancellationProbeState()
    let stream = AsyncStream<Int> { continuation in
        continuation.onTermination = { termination in
            state.termination = "\(termination)"
        }
    }
    let consumer = Task { @MainActor in
        var iterator = stream.makeAsyncIterator()
        state.enteredNext = true
        let value = await iterator.next()
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
    await asyncStreamCancelledConsumerProbe()
}
