@MainActor
func checkedThrowingContinuationAbandonmentProbe() async -> String {
    let abandoned = Task.immediate(executorPreference: nil) {
        do {
            let _: Int = try await withCheckedThrowingContinuation(
                isolation: MainActor.shared,
                function: "checkedThrowingContinuationAbandonmentProbe()"
            ) { _ in }
            return "unexpected-resume"
        } catch {
            return "unexpected-catch"
        }
    }

    return abandoned.isCancelled ? "unexpected-cancelled" : "caller-returned"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedThrowingContinuationAbandonmentProbe()
}
