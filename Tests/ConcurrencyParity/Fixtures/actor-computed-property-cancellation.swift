actor ParityCancellingComputedTarget {
    var stored = 0
    var entryOwnership = "unset"
    var resumeOwnership = "unset"

    var cancellingValue: Int {
        get async throws {
            entryOwnership = parityActorSegmentOwnership(self)
            stored += 1
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

actor ParityCancellingComputedCaller {
    func run(_ target: ParityCancellingComputedTarget) async -> String {
        let before = parityActorSegmentOwnership(self)
        var outcome = "missed"
        do {
            _ = try await target.cancellingValue
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
func actorComputedPropertyCancellationProbe() async -> String {
    let target = ParityCancellingComputedTarget()
    let caller = ParityCancellingComputedCaller()
    let task = Task { await caller.run(target) }
    await parityAwaitActorMessageSuspension()
    task.cancel()
    await parityResumeActorMessage()
    return await task.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorComputedPropertyCancellationProbe()
}
