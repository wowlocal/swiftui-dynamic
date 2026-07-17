final class AsyncStreamEscapedContinuationState: @unchecked Sendable {
    var continuation: AsyncStream<Int>.Continuation?
    var termination = "none"
}

@MainActor
func asyncStreamEscapedContinuationLifetimeProbe() async -> String {
    let state = AsyncStreamEscapedContinuationState()

    func discardSequence() {
        _ = AsyncStream<Int> { continuation in
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
    await asyncStreamEscapedContinuationLifetimeProbe()
}
