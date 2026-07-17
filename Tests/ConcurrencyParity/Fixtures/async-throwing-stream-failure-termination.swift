enum AsyncThrowingStreamTerminationError: Error {
    case stopped
}

final class AsyncThrowingStreamFailureTerminationState: @unchecked Sendable {
    var events: [String] = []
    var postFinishYield = "unset"
}

@MainActor
func asyncThrowingStreamFailureTerminationProbe() async -> String {
    let state = AsyncThrowingStreamFailureTerminationState()
    let stream = AsyncThrowingStream<Int, Error> { continuation in
        continuation.onTermination = { termination in
            let rendered = "\(termination)"
            state.events.append(
                rendered.contains("stopped") ? "finished-error" : "unexpected")
        }
        continuation.yield(5)
        continuation.finish(throwing: AsyncThrowingStreamTerminationError.stopped)
        state.events.append("after-finish")
        state.postFinishYield = "\(continuation.yield(9))"
    }

    var iterator = stream.makeAsyncIterator()
    let first = try? await iterator.next()
    do {
        _ = try await iterator.next()
        return "unexpected-success"
    } catch AsyncThrowingStreamTerminationError.stopped {
        return "\(first ?? -1):caught"
            + ":\(state.events.joined(separator: ",")):\(state.postFinishYield)"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamFailureTerminationProbe()
}
