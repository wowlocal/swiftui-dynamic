final class AsyncThrowingStreamScopeTerminationState: @unchecked Sendable {
    var termination = "none"
}

@MainActor
func asyncThrowingStreamScopeTerminationProbe() async -> String {
    let state = AsyncThrowingStreamScopeTerminationState()

    func scopedStream() {
        _ = AsyncThrowingStream<Int, Error> { continuation in
            continuation.onTermination = { termination in
                state.termination = "\(termination)"
            }
        }
    }

    scopedStream()
    return state.termination
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamScopeTerminationProbe()
}
