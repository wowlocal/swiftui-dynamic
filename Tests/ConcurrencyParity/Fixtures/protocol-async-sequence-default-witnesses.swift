protocol ProbeDefaultAsyncIteratorProtocol: AsyncIteratorProtocol
where Element == Int, Failure == Never {
    var nextValue: Int { get set }
}

extension ProbeDefaultAsyncIteratorProtocol {
    mutating func next() async -> Int? {
        guard nextValue <= 3 else { return nil }
        let value = nextValue
        nextValue += 1
        await Task.yield()
        return value
    }
}

struct ProbeDefaultAsyncIterator: ProbeDefaultAsyncIteratorProtocol {
    typealias Element = Int
    typealias Failure = Never
    var nextValue = 1
}

protocol ProbeDefaultAsyncSequenceProtocol: AsyncSequence
where Element == Int, Failure == Never,
      AsyncIterator == ProbeDefaultAsyncIterator {}

extension ProbeDefaultAsyncSequenceProtocol {
    func makeAsyncIterator() -> ProbeDefaultAsyncIterator {
        ProbeDefaultAsyncIterator()
    }
}

struct ProbeDefaultAsyncSequence: ProbeDefaultAsyncSequenceProtocol {
    typealias Element = Int
    typealias Failure = Never
    typealias AsyncIterator = ProbeDefaultAsyncIterator
}

func protocolAsyncSequenceDefaultWitnessesProbe() async -> String {
    var count = 0
    var total = 0
    for await value in ProbeDefaultAsyncSequence() {
        count += 1
        total += value
    }
    return "\(count):\(total)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await protocolAsyncSequenceDefaultWitnessesProbe()
}
