actor ParityComputedCounter {
    var stored = 0

    var next: String {
        let ownership = parityActorSegmentOwnership(self)
        guard ownership == "owned" else { return ownership }
        stored += 1
        return ownership + ":" + String(stored)
    }

    nonisolated var direct: String {
        parityActorSegmentOwnership(self)
    }

    func current() -> Int {
        stored
    }
}

@MainActor
func actorComputedPropertyProbe() async -> String {
    let counter = ParityComputedCounter()
    let first = await counter.next
    let second = await counter.next
    let direct = counter.direct
    let final = await counter.current()
    return first + "|" + second + "|" + direct + "|" + String(final)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorComputedPropertyProbe()
}
