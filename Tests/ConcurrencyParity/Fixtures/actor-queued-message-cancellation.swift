actor ParityQueuedCancellationActor {
    func holdActorSegment() {
        parityBlockActorUntilReleased()
    }

    func observeQueuedCancellation() -> String {
        parityActorSegmentOwnership(self)
            + ":" + (Task.isCancelled ? "cancelled" : "active")
    }
}

@MainActor
final class ParityQueuedCancellationMarker {
    var attempted = false
}

@MainActor
func actorQueuedMessageCancellationProbe() async -> String {
    let actor = ParityQueuedCancellationActor()
    let holder = Task.detached {
        await actor.holdActorSegment()
        return "released"
    }
    await parityAwaitActorBlockEntered()

    let marker = ParityQueuedCancellationMarker()
    let waiter = Task { @MainActor in
        marker.attempted = true
        return await actor.observeQueuedCancellation()
    }
    while !marker.attempted {
        await Task.yield()
    }

    waiter.cancel()
    let request = waiter.isCancelled ? "requested" : "missing"
    parityReleaseActorBlock()
    let holderOutcome = await holder.value
    let waiterOutcome = await waiter.value
    return request + "|" + holderOutcome + "|" + waiterOutcome
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorQueuedMessageCancellationProbe()
}
