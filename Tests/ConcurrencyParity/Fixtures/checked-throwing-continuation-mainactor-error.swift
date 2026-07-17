enum CheckedThrowingContinuationMainActorProbeError: Error {
    case failed
    case wrongBodyExecutor
}

@concurrent
nonisolated
func checkedThrowingContinuationMainActorErrorProbe() async -> String {
    let entered = parityCurrentExecutorLane()
    let controller = Task.detached {
        await parityAwaitTaskValueGateStarted()
        await parityOpenTaskValueGate()
    }

    do {
        let _: Int = try await withCheckedThrowingContinuation(
            isolation: MainActor.shared,
            function: #function
        ) { continuation in
            let bodyLane = parityCurrentExecutorLane()
            Task.detached {
                await parityWaitTaskValueGate()
                if bodyLane == "main" {
                    continuation.resume(
                        throwing:
                            CheckedThrowingContinuationMainActorProbeError
                                .failed)
                } else {
                    continuation.resume(
                        throwing:
                            CheckedThrowingContinuationMainActorProbeError
                                .wrongBodyExecutor)
                }
            }
        }
        return "missing-error"
    } catch CheckedThrowingContinuationMainActorProbeError.failed {
        _ = await controller.value
        let resumed = parityCurrentExecutorLane()
        return "\(entered)|main|\(resumed)"
    } catch CheckedThrowingContinuationMainActorProbeError
        .wrongBodyExecutor
    {
        return "wrong-body-executor"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedThrowingContinuationMainActorErrorProbe()
}
