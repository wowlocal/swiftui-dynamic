final class AsyncStreamBufferingOldestState: @unchecked Sendable {
    var yieldResults: [String] = []
}

@MainActor
func asyncStreamBufferingOldestProbe() async -> String {
    let state = AsyncStreamBufferingOldestState()
    let stream = AsyncStream<Int>(bufferingPolicy: .bufferingOldest(2)) {
        continuation in
        state.yieldResults.append("\(continuation.yield(1))")
        state.yieldResults.append("\(continuation.yield(2))")
        state.yieldResults.append("\(continuation.yield(3))")
        state.yieldResults.append("\(continuation.yield(4))")
        continuation.finish()
    }

    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    let terminal = await iterator.next()
    return "\(state.yieldResults.joined(separator: "|"))=>\(first ?? -1),\(second ?? -1),\(terminal == nil)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncStreamBufferingOldestProbe()
}
