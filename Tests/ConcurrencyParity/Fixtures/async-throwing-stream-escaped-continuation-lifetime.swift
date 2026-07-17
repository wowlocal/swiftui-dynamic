final class AsyncThrowingStreamEscapedContinuationState: @unchecked Sendable {
    var continuation: AsyncThrowingStream<Int, Error>.Continuation?
    var termination = "none"
}

@MainActor
func asyncThrowingStreamEscapedContinuationLifetimeProbe() async -> String {
    let state = AsyncThrowingStreamEscapedContinuationState()

    func discardSequence() {
        _ = AsyncThrowingStream<Int, Error> { continuation in
            state.continuation = continuation
            continuation.onTermination = { termination in
                state.termination = "\(termination)"
            }
        }
    }

    discardSequence()
    let afterSequenceRelease = state.termination
    let yieldAfterRelease = state.continuation!.yield(9)
    state.continuation = nil
    return "\(afterSequenceRelease):\(yieldAfterRelease):\(state.termination)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamEscapedContinuationLifetimeProbe()
}
