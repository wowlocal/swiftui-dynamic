@MainActor
func taskGroupThrowingNextCancellationProbe() async -> String {
    do {
        _ = try await withThrowingTaskGroup(of: String.self) { group in
            group.cancelAll()
            group.addTask {
                try Task.checkCancellation()
                return "missed"
            }
            _ = try await group.next()
            return "missed"
        }
        return "missed"
    } catch {
        let errorKind = type(of: error) == CancellationError.self
            ? "cancellation"
            : "wrong-error"
        let ownerState = Task.isCancelled ? "owner-cancelled" : "owner-active"
        return errorKind + ":" + ownerState
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingNextCancellationProbe()
}
