@MainActor
final class AsyncLetDeferAfterRecorder {
    var events: [String] = []
}

@MainActor
func deferAfterAsyncLetChild(
    _ recorder: AsyncLetDeferAfterRecorder
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
func leaveDeferAfterAsyncLetScope(
    _ recorder: AsyncLetDeferAfterRecorder
) async {
    async let unused = deferAfterAsyncLetChild(recorder)
    defer {
        recorder.events.append("defer")
    }
    await parityAwaitWaitStarted()
    recorder.events.append("scope-exit")
}

@MainActor
func asyncLetDeferAfterDeclarationProbe() async -> String {
    let recorder = AsyncLetDeferAfterRecorder()
    await leaveDeferAfterAsyncLetScope(recorder)
    recorder.events.append("after-scope")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetDeferAfterDeclarationProbe()
}
