@MainActor
final class ProbeAsyncSequenceEarlyExitLog {
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

struct ProbeEarlyExitAsyncSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        let log: ProbeAsyncSequenceEarlyExitLog
        var value = 0

        mutating func next() async -> Int? {
            value += 1
            await log.recordNext(value)
            await Task.yield()
            return value
        }
    }

    let log: ProbeAsyncSequenceEarlyExitLog

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(log: log)
    }
}

@MainActor
func protocolAsyncSequenceEarlyExitProbe() async -> String {
    let log = ProbeAsyncSequenceEarlyExitLog()
    var values = ""

    for await value in ProbeEarlyExitAsyncSequence(log: log) {
        defer {
            log.record("defer-\(value)")
        }
        values += "\(value)"
        if value == 2 {
            break
        }
    }
    log.record("after")
    return "\(values):\(log.nextCalls):\(log.events)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await protocolAsyncSequenceEarlyExitProbe()
}
