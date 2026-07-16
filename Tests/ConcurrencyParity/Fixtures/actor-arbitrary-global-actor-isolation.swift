actor ParityArbitraryGlobalExecutor {}
actor ParityEnumGlobalExecutor {}

@globalActor
struct ParityArbitraryGlobalActor {
    static let shared = ParityArbitraryGlobalExecutor()
}

@globalActor
enum ParityEnumGlobalActor {
    static let shared = ParityEnumGlobalExecutor()
}

func parityArbitraryGlobalActorDefault(
    expected: any Actor,
    isolation: isolated (any Actor)? = #isolation
) -> String {
    parityActorSegmentOwnership(expected)
        + ":" + parityCurrentIsolationMatches(expected)
}

@ParityArbitraryGlobalActor
func parityArbitraryGlobalActorEntry() -> String {
    let expected = ParityArbitraryGlobalActor.shared
    let direct = parityCurrentIsolationMatches(expected)
    let forwarded = parityArbitraryGlobalActorDefault(expected: expected)
    return direct + ":" + forwarded
}

@ParityEnumGlobalActor
func parityEnumGlobalActorEntry() -> String {
    let expected = ParityEnumGlobalActor.shared
    let direct = parityCurrentIsolationMatches(expected)
    let forwarded = parityArbitraryGlobalActorDefault(expected: expected)
    return direct + ":" + forwarded
}

@MainActor
func arbitraryGlobalActorIsolationProbe() async -> String {
    let structure = await parityArbitraryGlobalActorEntry()
    let enumeration = await parityEnumGlobalActorEntry()
    return structure + "|" + enumeration
}

@MainActor
func parityNativeOutput() async throws -> String {
    await arbitraryGlobalActorIsolationProbe()
}
