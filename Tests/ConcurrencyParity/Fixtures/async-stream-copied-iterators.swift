final class AsyncStreamCopiedIteratorsState: @unchecked Sendable {
    var continuation: AsyncStream<Int>.Continuation?
    var enteredCount = 0
}

@MainActor
func asyncStreamCopiedIteratorsProbe() async -> String {
    let state = AsyncStreamCopiedIteratorsState()
    let stream = AsyncStream<Int> { continuation in
        state.continuation = continuation
    }
    let seed = stream.makeAsyncIterator()
    let first = Task { @MainActor in
        var iterator = seed
        state.enteredCount += 1
        return await iterator.next(isolation: #isolation) ?? -1
    }
    let second = Task { @MainActor in
        var iterator = seed
        state.enteredCount += 1
        return await iterator.next(isolation: #isolation) ?? -1
    }

    while state.enteredCount != 2 {
        await Task.yield()
    }
    state.continuation!.yield(4)
    state.continuation!.yield(6)
    state.continuation!.finish()
    let values = [await first.value, await second.value].sorted()
    return "\(values[0]):\(values[1]):\(state.enteredCount)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncStreamCopiedIteratorsProbe()
}
