enum AsyncLetThrowingScopeError: Error {
    case failed
}

@MainActor
final class AsyncLetThrowingScopeRecorder {
    var events: [String] = []
}

@MainActor
func throwingScopeAsyncLetChild(
    _ recorder: AsyncLetThrowingScopeRecorder
) async -> String {
    recorder.events.append("child-start")
    do {
        try await parityWaitForever()
        recorder.events.append("child-finished")
    } catch is CancellationError {
        recorder.events.append("child-cancelled")
    } catch {
        recorder.events.append("wrong-child-error")
    }
    return "unused"
}

@MainActor
func throwFromAsyncLetScope(
    _ recorder: AsyncLetThrowingScopeRecorder
) async throws {
    async let unused = throwingScopeAsyncLetChild(recorder)
    await parityAwaitWaitStarted()
    recorder.events.append("scope-throw")
    throw AsyncLetThrowingScopeError.failed
}

@MainActor
func asyncLetThrowingScopeExitProbe() async -> String {
    let recorder = AsyncLetThrowingScopeRecorder()
    do {
        try await throwFromAsyncLetScope(recorder)
        recorder.events.append("missed")
    } catch {
        recorder.events.append("caught")
    }
    recorder.events.append("after-catch")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetThrowingScopeExitProbe()
}
