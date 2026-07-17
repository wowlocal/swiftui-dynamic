// Semantic subset of swiftlang/swift's pinned
// test/Concurrency/Runtime/async_stream.swift: a producer yields two values,
// finishes, and the consumer observes terminal nil. The local gate adds a real
// empty-stream suspension without depending on scheduler order.
@MainActor
func asyncStreamSuspendedConsumerProbe() async -> String {
    let stream = AsyncStream<Int> { continuation in
        Task { @MainActor in
            await Task.yield()
            continuation.yield(2)
            await Task.yield()
            continuation.yield(4)
            continuation.finish()
        }
    }

    var count = 0
    var total = 0
    for await value in stream {
        count += 1
        total += value
    }
    return "\(count):\(total)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncStreamSuspendedConsumerProbe()
}
