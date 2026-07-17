final class AsyncStreamScopeTerminationState: @unchecked Sendable {
    var termination = "none"
}

@MainActor
func asyncStreamScopeTerminationProbe() async -> String {
    let state = AsyncStreamScopeTerminationState()

    func scopedStream() {
        _ = AsyncStream<Int> { continuation in
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
    await asyncStreamScopeTerminationProbe()
}
