@MainActor
func checkedContinuationAbandonmentProbe() async -> String {
    let abandoned = Task.immediate(executorPreference: nil) {
        let _: Int = await withCheckedContinuation(
            isolation: MainActor.shared,
            function: "checkedContinuationAbandonmentProbe()"
        ) { _ in }
        return "unexpected-resume"
    }

    return abandoned.isCancelled ? "unexpected-cancelled" : "caller-returned"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedContinuationAbandonmentProbe()
}
