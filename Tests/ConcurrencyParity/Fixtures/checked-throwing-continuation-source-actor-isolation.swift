enum CheckedThrowingContinuationSourceActorProbeError: Error {
    case failed
    case wrongBodyExecutor
}

actor CheckedThrowingContinuationSourceIsolationProbeActor {
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
        let errorResult: String
        do {
            let _: Int = try await withCheckedThrowingContinuation {
                continuation in
                let ownership = parityActorSegmentOwnership(self)
                Task.detached {
                    await parityWaitTaskValueGate()
                    if ownership == "owned" {
                        continuation.resume(
                            throwing:
                                CheckedThrowingContinuationSourceActorProbeError
                                    .failed)
                    } else {
                        continuation.resume(
                            throwing:
                                CheckedThrowingContinuationSourceActorProbeError
                                    .wrongBodyExecutor)
                    }
                }
            }
            errorResult = "missing-error"
        } catch CheckedThrowingContinuationSourceActorProbeError.failed {
            errorResult = "owned:failed"
        } catch CheckedThrowingContinuationSourceActorProbeError
            .wrongBodyExecutor
        {
            errorResult = "wrong-body-executor"
        } catch {
            errorResult = "unexpected-error"
        }
        _ = await controller.value
        let after = parityActorSegmentOwnership(self)
        return "\(before):\(errorResult):\(after):\(reentryCount)"
    }
}

@concurrent
nonisolated
func checkedThrowingContinuationExplicitSourceActorProbe(
    _ actor: CheckedThrowingContinuationSourceIsolationProbeActor
) async -> String {
    let entered = parityCurrentExecutorLane()
    do {
        let _: Int = try await withCheckedThrowingContinuation(
            isolation: actor,
            function: #function
        ) { continuation in
            let ownership = parityAssertActorSegmentOwnership(actor)
            Task.detached {
                await Task.yield()
                if ownership == "owned" {
                    continuation.resume(
                        throwing:
                            CheckedThrowingContinuationSourceActorProbeError
                                .failed)
                } else {
                    continuation.resume(
                        throwing:
                            CheckedThrowingContinuationSourceActorProbeError
                                .wrongBodyExecutor)
                }
            }
        }
        return "missing-error"
    } catch CheckedThrowingContinuationSourceActorProbeError.failed {
        let resumed = parityCurrentExecutorLane()
        return "\(entered):owned:\(resumed)"
    } catch CheckedThrowingContinuationSourceActorProbeError
        .wrongBodyExecutor
    {
        return "wrong-body-executor"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func checkedThrowingContinuationSourceActorIsolationProbe() async -> String {
    let actor = CheckedThrowingContinuationSourceIsolationProbeActor()
    let explicit = await checkedThrowingContinuationExplicitSourceActorProbe(
        actor)
    let callerDefaulted = await actor.callerDefaulted()
    return "explicit=\(explicit)|default=\(callerDefaulted)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedThrowingContinuationSourceActorIsolationProbe()
}
