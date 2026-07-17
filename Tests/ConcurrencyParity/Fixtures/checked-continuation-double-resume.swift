nonisolated func checkedContinuationDoubleResumeProbe() async -> String {
    let value: Int = await withCheckedContinuation(
        isolation: nil,
        function: #function
    ) { continuation in
        continuation.resume(returning: 17)
        continuation.resume(returning: 38)
    }
    return "unexpected:\(value)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationDoubleResumeProbe()
}
