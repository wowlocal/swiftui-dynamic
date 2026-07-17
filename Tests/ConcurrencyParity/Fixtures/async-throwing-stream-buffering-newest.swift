final class AsyncThrowingStreamBufferingNewestState: @unchecked Sendable {
    var yieldResults: [String] = []
}

@MainActor
func asyncThrowingStreamBufferingNewestProbe() async -> String {
    let state = AsyncThrowingStreamBufferingNewestState()
    let stream = AsyncThrowingStream<Int, Error>(
        bufferingPolicy: .bufferingNewest(2)
    ) { continuation in
        state.yieldResults.append("\(continuation.yield(1))")
        state.yieldResults.append("\(continuation.yield(2))")
        state.yieldResults.append("\(continuation.yield(3))")
        state.yieldResults.append("\(continuation.yield(4))")
        continuation.finish()
    }

    var iterator = stream.makeAsyncIterator()
    let first = try? await iterator.next()
    let second = try? await iterator.next()
    let terminal = try? await iterator.next()
    return "\(state.yieldResults.joined(separator: "|"))"
        + "=>\(first ?? -1),\(second ?? -1),\(terminal == nil)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamBufferingNewestProbe()
}
