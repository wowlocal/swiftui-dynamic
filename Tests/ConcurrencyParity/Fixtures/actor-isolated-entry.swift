actor ActorIsolatedEntryProbe {
    func isolatedEntry() -> String {
        parityCurrentIsolationKind()
    }

    nonisolated func nonisolatedEntry() -> String {
        parityCurrentIsolationKind()
    }
}

@MainActor
func actorIsolatedEntryProbe() async -> String {
    let actor = ActorIsolatedEntryProbe()
    let isolated = await actor.isolatedEntry()
    let nonisolated = actor.nonisolatedEntry()
    return isolated + ":" + nonisolated
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorIsolatedEntryProbe()
}
