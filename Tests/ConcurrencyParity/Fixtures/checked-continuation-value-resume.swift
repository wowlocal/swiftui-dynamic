nonisolated func checkedContinuationValueResumeProbe() async -> String {
    let value: Int = await withCheckedContinuation(
        isolation: nil,
        function: #function
    ) { continuation in
        Task.detached {
            await Task.yield()
            continuation.resume(returning: 41)
        }
    }
    return "\(value)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationValueResumeProbe()
}
