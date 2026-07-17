final class AsyncThrowingStreamZeroCapacityState: @unchecked Sendable {
    var newestYieldResult = ""
    var oldestYieldResult = ""
}

@MainActor
func asyncThrowingStreamZeroCapacityProbe() async -> String {
    let state = AsyncThrowingStreamZeroCapacityState()
    let newest = AsyncThrowingStream<Int, Error>(
        bufferingPolicy: .bufferingNewest(0)
    ) { continuation in
        state.newestYieldResult = "\(continuation.yield(1))"
        continuation.finish()
    }
    var newestIterator = newest.makeAsyncIterator()
    let newestTerminal = try? await newestIterator.next()

    let oldest = AsyncThrowingStream<Int, Error>(
        bufferingPolicy: .bufferingOldest(0)
    ) { continuation in
        state.oldestYieldResult = "\(continuation.yield(2))"
        continuation.finish()
    }
    var oldestIterator = oldest.makeAsyncIterator()
    let oldestTerminal = try? await oldestIterator.next()

    return "newest:\(state.newestYieldResult):\(newestTerminal == nil)"
        + "|oldest:\(state.oldestYieldResult):\(oldestTerminal == nil)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamZeroCapacityProbe()
}
