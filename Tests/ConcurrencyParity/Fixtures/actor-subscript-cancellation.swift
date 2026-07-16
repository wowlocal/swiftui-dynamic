actor ParityCancellingSubscriptTarget {
    var stored = 0
    var entryOwnership = "unset"
    var resumeOwnership = "unset"

    subscript(_ increment: Int) -> Int {
        get async throws {
            entryOwnership = parityActorSegmentOwnership(self)
            stored += increment
            await paritySuspendActorMessage()
            resumeOwnership = parityActorSegmentOwnership(self)
            try Task.checkCancellation()
            return stored
        }
    }

    func recover() -> String {
        let recoveryOwnership = parityActorSegmentOwnership(self)
        stored += 1
        return entryOwnership + ":" + resumeOwnership
            + ":" + recoveryOwnership + ":" + String(stored)
    }
}

actor ParityCancellingSubscriptCaller {
    func run(_ target: ParityCancellingSubscriptTarget) async -> String {
        let before = parityActorSegmentOwnership(self)
        var outcome = "missed"
        do {
            _ = try await target[1]
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
func actorSubscriptCancellationProbe() async -> String {
    let target = ParityCancellingSubscriptTarget()
    let caller = ParityCancellingSubscriptCaller()
    let task = Task { await caller.run(target) }
    await parityAwaitActorMessageSuspension()
    task.cancel()
    await parityResumeActorMessage()
    return await task.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorSubscriptCancellationProbe()
}
