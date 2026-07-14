@MainActor
final class AsyncLetSeparateDeclarationRecorder {
    var events: [String] = []
    var started = 0
}

@MainActor
func separateDeclarationChild(
    _ name: String,
    recorder: AsyncLetSeparateDeclarationRecorder
) async -> String {
    recorder.events.append(name + "-start")
    recorder.started += 1
    do {
        try await parityWaitForever()
        recorder.events.append(name + "-finished")
    } catch is CancellationError {
        recorder.events.append(name + "-cancelled")
    } catch {
        recorder.events.append(name + "-wrong-error")
    }
    return name
}

@MainActor
func leaveSeparateAsyncLetDeclarationScope(
    _ recorder: AsyncLetSeparateDeclarationRecorder
) async {
    async let first = separateDeclarationChild("first", recorder: recorder)
    async let second = separateDeclarationChild("second", recorder: recorder)
    while recorder.started < 2 {
        await Task.yield()
    }
    recorder.events.append("scope-exit")
}

@MainActor
func asyncLetSeparateDeclarationCleanupOrderProbe() async -> String {
    let recorder = AsyncLetSeparateDeclarationRecorder()
    await leaveSeparateAsyncLetDeclarationScope(recorder)
    recorder.events.append("after-scope")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetSeparateDeclarationCleanupOrderProbe()
}
