enum AsyncThrowingStreamProbeError: Error {
    case stopped
}

@MainActor
func asyncThrowingStreamSuspendedFailureProbe() async -> String {
    let stream = AsyncThrowingStream<Int, Error> { continuation in
        Task { @MainActor in
            await Task.yield()
            continuation.yield(2)
            continuation.finish(throwing: AsyncThrowingStreamProbeError.stopped)
        }
    }

    var count = 0
    var total = 0
    do {
        for try await value in stream {
            count += 1
            total += value
        }
        return "unexpected-success"
    } catch AsyncThrowingStreamProbeError.stopped {
        return "\(count):\(total):caught"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamSuspendedFailureProbe()
}
