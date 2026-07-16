actor ParityInitializationActor {
    let initializationIsolation: String
    var value: Int

    init(seed: Int) {
        initializationIsolation = parityCurrentIsolationKind()
        value = seed
        value += 1
    }

    func snapshot() -> String {
        initializationIsolation
            + ":" + parityActorSegmentOwnership(self)
            + ":" + String(value)
    }
}

@MainActor
func actorInitializationProbe() async -> String {
    let actor = ParityInitializationActor(seed: 4)
    return await actor.snapshot()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorInitializationProbe()
}
