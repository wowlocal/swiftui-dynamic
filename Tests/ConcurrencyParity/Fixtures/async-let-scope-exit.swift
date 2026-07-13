@MainActor
final class AsyncLetScopeExitRecorder {
    var events: [String] = []
}

@MainActor
func unconsumedAsyncLetChild(
    _ recorder: AsyncLetScopeExitRecorder
) async -> String {
    recorder.events.append("child-start")
    do {
        try await parityWaitForever()
        recorder.events.append("child-finished")
    } catch is CancellationError {
        recorder.events.append("child-cancelled")
    } catch {
        recorder.events.append("wrong-error")
    }
    return "child-value"
}

@MainActor
func leaveAsyncLetScope(_ recorder: AsyncLetScopeExitRecorder) async {
    async let unused = unconsumedAsyncLetChild(recorder)
    await parityAwaitWaitStarted()
    recorder.events.append("scope-exit")
}

@MainActor
func asyncLetScopeExitProbe() async -> String {
    let recorder = AsyncLetScopeExitRecorder()
    await leaveAsyncLetScope(recorder)
    recorder.events.append("after-scope")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetScopeExitProbe()
}
