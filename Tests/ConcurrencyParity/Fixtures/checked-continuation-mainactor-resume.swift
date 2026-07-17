@concurrent
nonisolated
func checkedContinuationMainActorResumeProbe() async -> String {
    let entered = parityCurrentExecutorLane()
    let controller = Task.detached {
        await parityAwaitTaskValueGateStarted()
        await parityOpenTaskValueGate()
    }
    let bodyLane: String = await withCheckedContinuation(
        isolation: MainActor.shared,
        function: #function
    ) { continuation in
        let lane = parityCurrentExecutorLane()
        Task.detached {
            await parityWaitTaskValueGate()
            continuation.resume(returning: lane)
        }
    }
    _ = await controller.value
    let resumed = parityCurrentExecutorLane()
    return "\(entered)|\(bodyLane)|\(resumed)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationMainActorResumeProbe()
}
