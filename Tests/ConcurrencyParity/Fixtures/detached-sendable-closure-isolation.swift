@MainActor var sendableInheritedObservation = ""
@MainActor var sendableDetachedObservation = ""

@MainActor
func recordSendableDetachedObservation(_ value: String) {
    sendableDetachedObservation = value
}

@MainActor
func detachedSendableClosureIsolationProbe() async -> String {
    sendableInheritedObservation = ""
    sendableDetachedObservation = ""

    let inherited: Task<Void, Never> = Task { @Sendable in
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await Task.yield()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        sendableInheritedObservation = "\(before)|\(after)"
    }
    let detached: Task<Void, Never> = Task.detached { @Sendable in
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await Task.yield()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        await recordSendableDetachedObservation("\(before)|\(after)")
    }

    await inherited.value
    await detached.value
    return "\(sendableInheritedObservation)#\(sendableDetachedObservation)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedSendableClosureIsolationProbe()
}
