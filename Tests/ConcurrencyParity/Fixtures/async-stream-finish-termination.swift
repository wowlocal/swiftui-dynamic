final class AsyncStreamFinishProbeState: @unchecked Sendable {
    var trace = "none"
    var postFinishYield = "none"
}

@MainActor
func asyncStreamFinishTerminationProbe() async -> String {
    let state = AsyncStreamFinishProbeState()
    let stream = AsyncStream<Int> { continuation in
        continuation.onTermination = { termination in
            state.trace = "\(termination)"
        }
        continuation.yield(3)
        continuation.finish()
        state.trace += ",after-finish"
        state.postFinishYield = "\(continuation.yield(99))"
        continuation.finish()
    }

    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    let terminal = await iterator.next()
    let terminalAgain = await iterator.next()
    return "\(first ?? -1):\(terminal == nil):\(terminalAgain == nil):\(state.trace):\(state.postFinishYield)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncStreamFinishTerminationProbe()
}
