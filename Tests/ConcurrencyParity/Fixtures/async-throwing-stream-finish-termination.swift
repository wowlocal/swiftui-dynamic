final class AsyncThrowingStreamFinishState: @unchecked Sendable {
    var events: [String] = []
    var postFinishYield = "unset"
}

@MainActor
func asyncThrowingStreamFinishTerminationProbe() async -> String {
    let state = AsyncThrowingStreamFinishState()
    let stream = AsyncThrowingStream<Int, Error> { continuation in
        continuation.onTermination = { termination in
            state.events.append("\(termination)")
        }
        continuation.yield(3)
        continuation.finish()
        state.events.append("after-finish")
        state.postFinishYield = "\(continuation.yield(9))"
    }

    var iterator = stream.makeAsyncIterator()
    let first = try? await iterator.next()
    let second = try? await iterator.next()
    let third = try? await iterator.next()
    return "\(first ?? -1):\(second == nil):\(third == nil)"
        + ":\(state.events.joined(separator: ",")):\(state.postFinishYield)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamFinishTerminationProbe()
}
