@MainActor
func taskGroupCancellationLabel(_ isCancelled: Bool) -> String {
    if isCancelled {
        return "cancelled"
    }
    return "active"
}

@MainActor
func taskGroupIsCancelledProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        let before = taskGroupCancellationLabel(group.isCancelled)
        group.cancelAll()
        let after = taskGroupCancellationLabel(group.isCancelled)
        return before + ":" + after
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupIsCancelledProbe()
}
