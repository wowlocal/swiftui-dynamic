@MainActor var detachedExplicitMainActorObservation = ""
@MainActor var detachedPlainObservation = ""

@MainActor
func recordDetachedPlainObservation(_ value: String) {
    detachedPlainObservation = value
}

@MainActor
func detachedExplicitMainActorClosureProbe() async -> String {
    detachedExplicitMainActorObservation = ""
    detachedPlainObservation = ""
    let explicit: Task<Void, Never> = Task.detached { @MainActor @Sendable in
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await Task.yield()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        detachedExplicitMainActorObservation = "\(before)|\(after)"
    }
    let plain: Task<Void, Never> = Task.detached {
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await Task.yield()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        await recordDetachedPlainObservation("\(before)|\(after)")
    }

    await explicit.value
    await plain.value
    return "\(detachedExplicitMainActorObservation)#\(detachedPlainObservation)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedExplicitMainActorClosureProbe()
}
