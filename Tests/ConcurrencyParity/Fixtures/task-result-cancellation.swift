@MainActor
func taskResultCancellationProbe() async -> String {
    let handle = Task {
        try await parityWaitForever()
        return "finished"
    }
    await parityAwaitWaitStarted()
    handle.cancel()

    switch await handle.result {
    case .success:
        return "unexpected-success"
    case .failure:
        return "failure"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskResultCancellationProbe()
}
