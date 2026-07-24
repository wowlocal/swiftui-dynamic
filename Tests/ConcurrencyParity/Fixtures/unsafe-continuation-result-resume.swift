enum UnsafeContinuationResultProbeError: Error {
    case failed
}

nonisolated func unsafeContinuationResultValue(
    _ result: Result<Int, UnsafeContinuationResultProbeError>
) async throws -> Int {
    try await withUnsafeThrowingContinuation(isolation: nil) { continuation in
        Task.detached {
            await Task.yield()
            let widened = result.mapError { $0 as Error }
            continuation.resume(with: widened)
        }
    }
}

nonisolated func unsafeContinuationVoidResult() async throws {
    try await withUnsafeThrowingContinuation(isolation: nil) { continuation in
        Task.detached {
            await Task.yield()
            let result: Result<
                Void, UnsafeContinuationResultProbeError
            > = .success(())
            continuation.resume(with: result)
        }
    }
}

nonisolated func unsafeContinuationResultResumeProbe() async -> String {
    let success: Result<
        Int, UnsafeContinuationResultProbeError
    > = .success(29)
    let value: Int
    do {
        value = try await unsafeContinuationResultValue(success)
    } catch {
        return "unexpected-value-error"
    }

    let failure: Result<
        Int, UnsafeContinuationResultProbeError
    > = .failure(UnsafeContinuationResultProbeError.failed)
    let errorResult: String
    do {
        _ = try await unsafeContinuationResultValue(failure)
        errorResult = "missing-error"
    } catch UnsafeContinuationResultProbeError.failed {
        errorResult = "failed"
    } catch {
        errorResult = "unexpected-error"
    }

    do {
        try await unsafeContinuationVoidResult()
    } catch {
        return "unexpected-void-error"
    }

    return "value:\(value)|error:\(errorResult)|void:resumed"
}

@MainActor
func parityNativeOutput() async -> String {
    await unsafeContinuationResultResumeProbe()
}
