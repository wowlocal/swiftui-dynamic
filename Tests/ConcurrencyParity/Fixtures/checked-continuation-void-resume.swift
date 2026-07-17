nonisolated func checkedContinuationVoidResumeProbe() async -> String {
    let _: Void = await withCheckedContinuation(
        isolation: nil,
        function: #function
    ) { continuation in
        Task.detached {
            await Task.yield()
            continuation.resume()
        }
    }
    return "void-resumed"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationVoidResumeProbe()
}
