@MainActor
func asyncThrowingStreamCopiedIteratorsProbe() async -> String {
    let stream = AsyncThrowingStream<Int, Error> { _ in }
    let seed = stream.makeAsyncIterator()
    let first = Task.immediate { @MainActor in
        var iterator = seed
        return try? await iterator.next(isolation: #isolation)
    }
    var second = seed
    _ = try? await second.next(isolation: #isolation)
    _ = await first.value
    return "unexpected"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncThrowingStreamCopiedIteratorsProbe()
}
