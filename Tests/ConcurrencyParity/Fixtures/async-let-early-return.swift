@MainActor
final class AsyncLetEarlyReturnRecorder {
    var events: [String] = []
}

@MainActor
func earlyReturnAsyncLetChild(
    _ recorder: AsyncLetEarlyReturnRecorder
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
    return "unused"
}

@MainActor
func leaveAsyncLetScopeEarly(
    _ recorder: AsyncLetEarlyReturnRecorder
) async -> String {
    async let unused = earlyReturnAsyncLetChild(recorder)
    await parityAwaitWaitStarted()
    recorder.events.append("early-return")
    return "returned"
}

@MainActor
func asyncLetEarlyReturnProbe() async -> String {
    let recorder = AsyncLetEarlyReturnRecorder()
    let result = await leaveAsyncLetScopeEarly(recorder)
    recorder.events.append(result)
    recorder.events.append("after-return")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetEarlyReturnProbe()
}
