enum ProbeAsyncSequenceError: Error {
    case stopped
}

struct ProbeThrowingAsyncSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        var nextValue = 1

        mutating func next() async throws -> Int? {
            let value = nextValue
            nextValue += 1
            await Task.yield()
            if value == 3 {
                throw ProbeAsyncSequenceError.stopped
            }
            return value
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
}

@MainActor
func protocolAsyncSequenceThrowingProbe() async -> String {
    var count = 0
    var total = 0
    do {
        for try await value in ProbeThrowingAsyncSequence() {
            count += 1
            total += value
        }
        return "unexpected-success"
    } catch ProbeAsyncSequenceError.stopped {
        return "\(count):\(total):caught"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await protocolAsyncSequenceThrowingProbe()
}
