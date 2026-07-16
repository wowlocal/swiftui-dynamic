actor ParityDefaultedIsolationCounter {
    func inheritedDefault() -> String {
        defaultedIsolationObservation(expected: self)
    }
}

func defaultedIsolationObservation(
    expected: ParityDefaultedIsolationCounter,
    isolation: isolated (any Actor)? = #isolation
) -> String {
    parityActorSegmentOwnership(expected)
        + ":" + parityCurrentIsolationKind()
}

nonisolated func defaultedIsolationFromNonisolated(
    expected: ParityDefaultedIsolationCounter
) -> String {
    defaultedIsolationObservation(expected: expected)
}

@MainActor
func actorIsolatedParameterDefaultsProbe() async -> String {
    let counter = ParityDefaultedIsolationCounter()
    let inherited = await counter.inheritedDefault()
    let explicitActor = await defaultedIsolationObservation(
        expected: counter,
        isolation: counter)
    let explicitNil = defaultedIsolationObservation(
        expected: counter,
        isolation: nil)
    let defaultNil = defaultedIsolationFromNonisolated(expected: counter)
    return inherited + "|" + explicitActor
        + "|" + explicitNil + "|" + defaultNil
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorIsolatedParameterDefaultsProbe()
}
