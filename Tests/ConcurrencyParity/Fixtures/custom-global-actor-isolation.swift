@globalActor
actor ParityGlobalActor {
    static let shared = ParityGlobalActor()
}

@ParityGlobalActor
func parityGlobalActorEntry() -> String {
    parityCurrentIsolationMatches(ParityGlobalActor.shared)
}

nonisolated func parityGlobalActorNonisolatedEntry() -> String {
    parityCurrentIsolationMatches(ParityGlobalActor.shared)
}

@MainActor
func customGlobalActorIsolationProbe() async -> String {
    let isolated = await parityGlobalActorEntry()
    let nonisolated = parityGlobalActorNonisolatedEntry()
    return isolated + ":" + nonisolated
}

@MainActor
func parityNativeOutput() async throws -> String {
    await customGlobalActorIsolationProbe()
}
