enum CheckedContinuationResultSpellingsProbeError: Error {
    case failed
}

nonisolated func checkedNonthrowingContinuationResultValue(
    _ result: Result<Int, Never>
) async -> Int {
    await withCheckedContinuation(
        isolation: nil,
        function: #function
    ) { continuation in
        Task.detached {
            await Task.yield()
            continuation.resume(with: result)
        }
    }
}

nonisolated func checkedExistentialContinuationResultValue(
    _ result: Result<Int, any Error>
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

nonisolated func checkedContinuationResultSpellingsProbe() async -> String {
    let neverResult: Result<Int, Never> = .success(31)
    let neverValue = await checkedNonthrowingContinuationResultValue(
        neverResult)

    let existentialSuccess: Result<Int, any Error> = .success(37)
    let existentialValue: Int
    do {
        existentialValue = try await checkedExistentialContinuationResultValue(
            existentialSuccess)
    } catch {
        return "unexpected-success-error"
    }

    let existentialFailure: Result<Int, any Error> = .failure(
        CheckedContinuationResultSpellingsProbeError.failed)
    let existentialError: String
    do {
        _ = try await checkedExistentialContinuationResultValue(
            existentialFailure)
        existentialError = "missing-error"
    } catch CheckedContinuationResultSpellingsProbeError.failed {
        existentialError = "failed"
    } catch {
        existentialError = "unexpected-error"
    }

    return "never:\(neverValue)|any-success:\(existentialValue)"
        + "|any-error:\(existentialError)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationResultSpellingsProbe()
}
