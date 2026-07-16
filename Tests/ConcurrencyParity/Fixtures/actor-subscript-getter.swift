actor ParitySubscriptCounter {
    var stored = 0

    subscript(_ increment: Int) -> String {
        let ownership = parityActorSegmentOwnership(self)
        guard ownership == "owned" else { return ownership }
        stored += increment
        return ownership + ":" + String(stored)
    }

    nonisolated subscript(direct first: Int, _ second: Int) -> String {
        parityActorSegmentOwnership(self)
    }

    func current() -> Int {
        stored
    }
}

@MainActor
func actorSubscriptGetterProbe() async -> String {
    let counter = ParitySubscriptCounter()
    let first = await counter[1]
    let second = await counter[2]
    let direct = counter[direct: 0, 0]
    let final = await counter.current()
    return first + "|" + second + "|" + direct + "|" + String(final)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorSubscriptGetterProbe()
}
