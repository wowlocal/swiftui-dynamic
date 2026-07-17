final class AsyncStreamMultipleConsumersState: @unchecked Sendable {
    var continuation: AsyncStream<Int>.Continuation?
    var enteredCount = 0
}

@MainActor
func asyncStreamMultipleConsumersProbe() async -> String {
    let state = AsyncStreamMultipleConsumersState()
    let stream = AsyncStream<Int> { continuation in
        state.continuation = continuation
    }
    let first = Task { @MainActor in
        var iterator = stream.makeAsyncIterator()
        state.enteredCount += 1
        return await iterator.next() == nil
    }
    let second = Task { @MainActor in
        var iterator = stream.makeAsyncIterator()
        state.enteredCount += 1
        return await iterator.next() == nil
    }

    while state.enteredCount != 2 {
        await Task.yield()
    }
    state.continuation!.finish()
    return "\(await first.value):\(await second.value):\(state.enteredCount)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncStreamMultipleConsumersProbe()
}
