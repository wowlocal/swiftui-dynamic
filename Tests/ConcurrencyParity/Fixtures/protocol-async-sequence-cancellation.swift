@MainActor
final class ProbeAsyncSequenceCancellationGate {
    var entered = false
    var isOpen = false

    func suspend() async {
        entered = true
        while !isOpen {
            await Task.yield()
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        isOpen = true
    }
}

struct ProbeCancellationAsyncSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        let gate: ProbeAsyncSequenceCancellationGate
        var step = 0

        mutating func next() async -> Int? {
            guard step == 0 else { return nil }
            step = 1
            await gate.suspend()
            return Task.isCancelled ? 7 : -7
        }
    }

    let gate: ProbeAsyncSequenceCancellationGate

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(gate: gate)
    }
}

@MainActor
func protocolAsyncSequenceCancellationProbe() async -> String {
    let gate = ProbeAsyncSequenceCancellationGate()
    let task = Task { @MainActor in
        var count = 0
        var total = 0
        for await value in ProbeCancellationAsyncSequence(gate: gate) {
            count += 1
            total += value
        }
        return "\(count):\(total):\(Task.isCancelled)"
    }

    await gate.waitUntilEntered()
    task.cancel()
    gate.release()
    return "\(await task.value):\(task.isCancelled)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await protocolAsyncSequenceCancellationProbe()
}
