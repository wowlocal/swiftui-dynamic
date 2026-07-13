@MainActor
func catchTaskCancellation() async -> String {
    do {
        try await parityWaitForever()
        return "not-cancelled"
    } catch is CancellationError {
        return "caught"
    } catch {
        return "wrong-error"
    }
}

@MainActor
func taskCancellationCaughtProbe() async -> String {
    let handle = Task {
        await catchTaskCancellation()
    }
    await parityAwaitWaitStarted()
    handle.cancel()

    let cancellationState = handle.isCancelled ? "cancelled" : "not-marked"
    switch await handle.result {
    case .success(let value):
        return "success:" + value + "," + cancellationState
    case .failure:
        return "failure," + cancellationState
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskCancellationCaughtProbe()
}
