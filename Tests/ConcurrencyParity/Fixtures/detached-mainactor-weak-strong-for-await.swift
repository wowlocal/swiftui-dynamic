@MainActor
final class DetachedMainActorForAwaitGate {
    var entered = false
    var isOpen = false

    func suspendUntilOpen() async {
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

struct DetachedMainActorUpdateSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        let values: [Int]
        let gate: DetachedMainActorForAwaitGate?
        var index = 0

        mutating func next() async -> Int? {
            if index == 0, let gate {
                await gate.suspendUntilOpen()
            }
            guard index < values.count else { return nil }
            let value = values[index]
            index += 1
            await Task.yield()
            return value
        }
    }

    let values: [Int]
    let gate: DetachedMainActorForAwaitGate?

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(values: values, gate: gate)
    }
}

@MainActor
final class DetachedMainActorForAwaitKey {
    let values: [Int]
    let gate: DetachedMainActorForAwaitGate?

    init(values: [Int], gate: DetachedMainActorForAwaitGate?) {
        self.values = values
        self.gate = gate
    }
}

@MainActor
func detachedMainActorUpdates(
    _ key: DetachedMainActorForAwaitKey
) -> DetachedMainActorUpdateSequence {
    DetachedMainActorUpdateSequence(values: key.values, gate: key.gate)
}

@MainActor
final class DetachedMainActorForAwaitLog {
    var observations: [String] = []

    func record() {
        observations.append(
            parityCurrentIsolationMatches(MainActor.shared))
    }
}

@MainActor
final class DetachedMainActorForAwaitOwner {
    private var onObjectChanged: (() -> Void)?
    let key: DetachedMainActorForAwaitKey

    init(
        key: DetachedMainActorForAwaitKey,
        log: DetachedMainActorForAwaitLog
    ) {
        self.key = key
        onObjectChanged = { log.record() }
    }

    func observe() -> Task<Void, Never> {
        .detached(priority: .userInitiated) {
            @MainActor @Sendable [weak self, key] in
            for await _ in detachedMainActorUpdates(key) {
                guard let self else { return }
                self.onObjectChanged?()
            }
        }
    }
}

@MainActor
func detachedMainActorWeakStrongForAwaitProbe() async -> String {
    let liveLog = DetachedMainActorForAwaitLog()
    let liveOwner = DetachedMainActorForAwaitOwner(
        key: DetachedMainActorForAwaitKey(values: [1, 2], gate: nil),
        log: liveLog)
    await liveOwner.observe().value

    let gate = DetachedMainActorForAwaitGate()
    let releasedLog = DetachedMainActorForAwaitLog()
    var releasedOwner: DetachedMainActorForAwaitOwner? =
        DetachedMainActorForAwaitOwner(
            key: DetachedMainActorForAwaitKey(values: [1, 2], gate: gate),
            log: releasedLog)
    let releasedTask = releasedOwner!.observe()
    await gate.waitUntilEntered()
    releasedOwner = nil
    gate.release()
    await releasedTask.value

    return "\(liveLog.observations.joined(separator: ","))"
        + ":\(liveLog.observations.count)"
        + "#\(releasedLog.observations.count)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedMainActorWeakStrongForAwaitProbe()
}
