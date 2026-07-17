actor CheckedContinuationSourceIsolationProbeActor {
    private var reentryCount = 0

    private func recordReentryAndOpenGate() async {
        reentryCount += 1
        await parityOpenTaskValueGate()
    }

    func callerDefaulted() async -> String {
        let before = parityActorSegmentOwnership(self)
        let controller = Task.detached {
            await parityAwaitTaskValueGateStarted()
            await self.recordReentryAndOpenGate()
        }
        let bodyOwnership: String = await withCheckedContinuation {
            continuation in
            let ownership = parityActorSegmentOwnership(self)
            Task.detached {
                await parityWaitTaskValueGate()
                continuation.resume(returning: ownership)
            }
        }
        _ = await controller.value
        let after = parityActorSegmentOwnership(self)
        return "\(before):\(bodyOwnership):\(after):\(reentryCount)"
    }
}

@concurrent
nonisolated
func checkedContinuationExplicitSourceActorProbe(
    _ actor: CheckedContinuationSourceIsolationProbeActor
) async -> String {
    let entered = parityCurrentExecutorLane()
    let bodyOwnership: String = await withCheckedContinuation(
        isolation: actor,
        function: #function
    ) { continuation in
        let ownership = parityAssertActorSegmentOwnership(actor)
        Task.detached {
            await Task.yield()
            continuation.resume(returning: ownership)
        }
    }
    let resumed = parityCurrentExecutorLane()
    return "\(entered):\(bodyOwnership):\(resumed)"
}

@MainActor
func checkedContinuationSourceActorIsolationProbe() async -> String {
    let actor = CheckedContinuationSourceIsolationProbeActor()
    let explicit = await checkedContinuationExplicitSourceActorProbe(actor)
    let callerDefaulted = await actor.callerDefaulted()
    return "explicit=\(explicit)|default=\(callerDefaulted)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationSourceActorIsolationProbe()
}
