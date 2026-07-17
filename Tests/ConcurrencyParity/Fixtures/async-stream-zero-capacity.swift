final class AsyncStreamZeroCapacityState: @unchecked Sendable {
    var newestYieldResult = ""
    var oldestYieldResult = ""
}

@MainActor
func asyncStreamZeroCapacityProbe() async -> String {
    let state = AsyncStreamZeroCapacityState()
    let newest = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(0)) {
        continuation in
        state.newestYieldResult = "\(continuation.yield(1))"
        continuation.finish()
    }
    var newestIterator = newest.makeAsyncIterator()
    let newestTerminal = await newestIterator.next()

    let oldest = AsyncStream<Int>(bufferingPolicy: .bufferingOldest(0)) {
        continuation in
        state.oldestYieldResult = "\(continuation.yield(2))"
        continuation.finish()
    }
    var oldestIterator = oldest.makeAsyncIterator()
    let oldestTerminal = await oldestIterator.next()

    return "newest:\(state.newestYieldResult):\(newestTerminal == nil)"
        + "|oldest:\(state.oldestYieldResult):\(oldestTerminal == nil)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncStreamZeroCapacityProbe()
}
