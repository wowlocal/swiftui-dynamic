struct ProbeAsyncSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        var nextValue = 1

        mutating func next() async -> Int? {
            guard nextValue <= 3 else { return nil }
            let value = nextValue
            nextValue += 1
            await Task.yield()
            return value
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
}

@MainActor
func protocolAsyncSequenceIterationProbe() async -> String {
    var count = 0
    var total = 0
    for await value in ProbeAsyncSequence() {
        count += 1
        total += value
    }
    return "\(count):\(total)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await protocolAsyncSequenceIterationProbe()
}
