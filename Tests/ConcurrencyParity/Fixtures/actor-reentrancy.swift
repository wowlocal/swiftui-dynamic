actor ParityReentrantCounter {
    var value = 0

    func suspendedMutation() async -> String {
        let ownershipBefore = parityActorSegmentOwnership(self)
        value = 1
        await paritySuspendActorMessage()
        let ownershipAfter = parityActorSegmentOwnership(self)
        let observation = value == 2 ? "interleaved" : "stale"
        value = 3
        return ownershipBefore + ":" + ownershipAfter + ":" + observation
    }

    func interleavingMutation() -> String {
        let ownership = parityActorSegmentOwnership(self)
        value = 2
        return ownership
    }

    func current() -> Int {
        value
    }
}

@MainActor
func actorReentrancyProbe() async -> String {
    let counter = ParityReentrantCounter()
    async let suspended = counter.suspendedMutation()
    await parityAwaitActorMessageSuspension()
    let interleaving = await counter.interleavingMutation()
    await parityResumeActorMessage()
    let resumed = await suspended
    let final = await counter.current()
    return resumed + ":" + interleaving + ":" + String(final)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorReentrancyProbe()
}
