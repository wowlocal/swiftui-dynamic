enum CheckedThrowingContinuationDoubleResumeProbeError: Error {
    case failed
}

nonisolated func checkedThrowingContinuationDoubleResumeProbe() async -> String {
    do {
        let value: Int = try await withCheckedThrowingContinuation(
            isolation: nil,
            function: #function
        ) { continuation in
            continuation.resume(returning: 17)
            continuation.resume(
                throwing: CheckedThrowingContinuationDoubleResumeProbeError
                    .failed)
        }
        return "unexpected:\(value)"
    } catch {
        return "unexpected-catch"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedThrowingContinuationDoubleResumeProbe()
}
