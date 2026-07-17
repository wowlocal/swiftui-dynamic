@MainActor
final class ProbeAsyncSequenceReturnContinueLog {
    var nextCalls = 0
    var events = ""

    func recordNext(_ value: Int) {
        nextCalls += 1
        record("next-\(value)")
    }

    func record(_ event: String) {
        if !events.isEmpty {
            events += ","
        }
        events += event
    }
}

struct ProbeReturnContinueAsyncSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        let log: ProbeAsyncSequenceReturnContinueLog
        var value = 0

        mutating func next() async -> Int? {
            value += 1
            await log.recordNext(value)
            await Task.yield()
            return value
        }
    }

    let log: ProbeAsyncSequenceReturnContinueLog

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(log: log)
    }
}

@MainActor
func consumeProbeReturnContinueSequence(
    _ log: ProbeAsyncSequenceReturnContinueLog
) async -> String {
    defer {
        log.record("consumer-defer")
    }

    for await value in ProbeReturnContinueAsyncSequence(log: log) {
        defer {
            log.record("defer-\(value)")
        }
        if value == 1 {
            log.record("continue-1")
            continue
        }
        if value == 3 {
            log.record("return-3")
            return "returned-3"
        }
        log.record("body-\(value)")
    }
    return "fell-through"
}

@MainActor
func protocolAsyncSequenceReturnContinueProbe() async -> String {
    let log = ProbeAsyncSequenceReturnContinueLog()
    let result = await consumeProbeReturnContinueSequence(log)
    log.record("after")
    return "\(result):\(log.nextCalls):\(log.events)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await protocolAsyncSequenceReturnContinueProbe()
}
