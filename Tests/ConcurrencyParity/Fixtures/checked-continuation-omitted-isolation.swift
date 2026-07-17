enum CheckedContinuationOmittedIsolationProbeError: Error {
    case failed
    case wrongBodyExecutor
}

@concurrent
nonisolated
func checkedContinuationOmittedNonisolatedProbe() async -> String {
    let entered = parityCurrentExecutorLane()
    let bodyLane: String = await withCheckedContinuation(
        function: #function
    ) { continuation in
        let lane = parityCurrentExecutorLane()
        Task.detached {
            await Task.yield()
            continuation.resume(returning: lane)
        }
    }
    let resumed = parityCurrentExecutorLane()
    return "\(entered):\(bodyLane):\(resumed)"
}

@MainActor
func checkedThrowingContinuationOmittedMainActorProbe() async -> String {
    let entered = parityCurrentExecutorLane()
    do {
        let _: Int = try await withCheckedThrowingContinuation(
            function: #function
        ) { continuation in
            let bodyLane = parityCurrentExecutorLane()
            Task.detached {
                await Task.yield()
                if bodyLane == "main" {
                    continuation.resume(
                        throwing:
                            CheckedContinuationOmittedIsolationProbeError
                                .failed)
                } else {
                    continuation.resume(
                        throwing:
                            CheckedContinuationOmittedIsolationProbeError
                                .wrongBodyExecutor)
                }
            }
        }
        return "missing-error"
    } catch CheckedContinuationOmittedIsolationProbeError.failed {
        let resumed = parityCurrentExecutorLane()
        return "\(entered):main:\(resumed)"
    } catch CheckedContinuationOmittedIsolationProbeError.wrongBodyExecutor {
        return "wrong-body-executor"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func checkedContinuationOmittedIsolationProbe() async -> String {
    let nonisolated = await checkedContinuationOmittedNonisolatedProbe()
    let mainActor = await checkedThrowingContinuationOmittedMainActorProbe()
    return "nonisolated=\(nonisolated)|main=\(mainActor)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationOmittedIsolationProbe()
}
