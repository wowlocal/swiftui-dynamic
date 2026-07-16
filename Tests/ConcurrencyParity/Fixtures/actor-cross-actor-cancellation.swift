actor ParityCancellationTarget {
    var stored = 0
    var entryOwnership = "unset"
    var resumeOwnership = "unset"

    func cancellationPoint() async throws {
        entryOwnership = parityActorSegmentOwnership(self)
        stored += 1
        await paritySuspendActorMessage()
        resumeOwnership = parityActorSegmentOwnership(self)
        try Task.checkCancellation()
    }

    func recover() -> String {
        let recoveryOwnership = parityActorSegmentOwnership(self)
        stored += 1
        return entryOwnership + ":" + resumeOwnership
            + ":" + recoveryOwnership + ":" + String(stored)
    }
}

actor ParityCancellationCaller {
    func run(_ target: ParityCancellationTarget) async -> String {
        let before = parityActorSegmentOwnership(self)
        var outcome = "missed"
        do {
            try await target.cancellationPoint()
        } catch is CancellationError {
            outcome = "cancelled"
        } catch {
            outcome = "other"
        }
        let afterCancellation = parityActorSegmentOwnership(self)
        let recovered = await target.recover()
        let afterRecovery = parityActorSegmentOwnership(self)
        return before + "|" + outcome + "|" + afterCancellation
            + "|" + recovered + "|" + afterRecovery
    }
}

@MainActor
func actorCrossActorCancellationProbe() async -> String {
    let target = ParityCancellationTarget()
    let caller = ParityCancellationCaller()
    let task = Task { await caller.run(target) }
    await parityAwaitActorMessageSuspension()
    task.cancel()
    await parityResumeActorMessage()
    return await task.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorCrossActorCancellationProbe()
}
