enum CheckedThrowingContinuationResultProbeError: Error {
    case failed
}

nonisolated func checkedThrowingContinuationResultValue(
    _ result: Result<Int, CheckedThrowingContinuationResultProbeError>
) async throws -> Int {
    try await withCheckedThrowingContinuation(
        isolation: nil,
        function: #function
    ) { continuation in
        Task.detached {
            await Task.yield()
            continuation.resume(with: result)
        }
    }
}

nonisolated func checkedThrowingContinuationResultResumeProbe()
    async -> String
{
    let success: Result<
        Int, CheckedThrowingContinuationResultProbeError
    > = .success(29)
    let value: Int
    do {
        value = try await checkedThrowingContinuationResultValue(success)
    } catch {
        return "unexpected-value-error"
    }

    let failure: Result<
        Int, CheckedThrowingContinuationResultProbeError
    > = .failure(CheckedThrowingContinuationResultProbeError.failed)
    let errorResult: String
    do {
        _ = try await checkedThrowingContinuationResultValue(failure)
        errorResult = "missing-error"
    } catch CheckedThrowingContinuationResultProbeError.failed {
        errorResult = "failed"
    } catch {
        errorResult = "unexpected-error"
    }

    return "value:\(value)|error:\(errorResult)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedThrowingContinuationResultResumeProbe()
}
