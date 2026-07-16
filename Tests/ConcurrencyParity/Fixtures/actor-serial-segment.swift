actor ParitySerialCounter {
    var value = 0

    func increment() -> String {
        let ownership = parityActorSegmentOwnership(self)
        value += 1
        return ownership
    }

    func current() -> Int {
        value
    }
}

@MainActor
func actorSerialSegmentProbe() async -> String {
    let counter = ParitySerialCounter()
    async let first = counter.increment()
    async let second = counter.increment()
    let ownership = await first + ":" + second
    let final = await counter.current()
    return ownership + ":" + String(final)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorSerialSegmentProbe()
}
