@MainActor
final class AsyncLetDeferBeforeRecorder {
    var events: [String] = []
}

@MainActor
func deferBeforeAsyncLetChild(
    _ recorder: AsyncLetDeferBeforeRecorder
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
func leaveDeferBeforeAsyncLetScope(
    _ recorder: AsyncLetDeferBeforeRecorder
) async {
    defer {
        recorder.events.append("defer")
    }
    async let unused = deferBeforeAsyncLetChild(recorder)
    await parityAwaitWaitStarted()
    recorder.events.append("scope-exit")
}

@MainActor
func asyncLetDeferBeforeDeclarationProbe() async -> String {
    let recorder = AsyncLetDeferBeforeRecorder()
    await leaveDeferBeforeAsyncLetScope(recorder)
    recorder.events.append("after-scope")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetDeferBeforeDeclarationProbe()
}
