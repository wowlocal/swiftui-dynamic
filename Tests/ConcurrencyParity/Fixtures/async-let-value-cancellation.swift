@MainActor
final class AsyncLetValueCancellationRecorder {
    nonisolated(unsafe) var events: [String] = []
    var parentWaiting = false
}

@MainActor
func cancellableAsyncLetChild(
    _ recorder: AsyncLetValueCancellationRecorder
) async throws -> String {
    try await withTaskCancellationHandler(operation: {
        recorder.events.append("child-start")
        try await parityWaitForever()
        return "wrong"
    }, onCancel: {
        recorder.events.append("child-cancelled")
    })
}

@MainActor
func asyncLetValueCancellationProbe() async -> String {
    let recorder = AsyncLetValueCancellationRecorder()
    let parent = Task {
        async let value = try cancellableAsyncLetChild(recorder)
        await parityAwaitWaitStarted()
        recorder.events.append("parent-await")
        recorder.parentWaiting = true
        do {
            _ = try await value
            recorder.events.append("missed")
        } catch is CancellationError {
            recorder.events.append("parent-caught")
        } catch {
            recorder.events.append("wrong-error")
        }
    }

    while !recorder.parentWaiting {
        await Task.yield()
    }
    parent.cancel()
    do {
        try await parent.value
        recorder.events.append("parent-finished")
    } catch is CancellationError {
        recorder.events.append("outer-caught")
    } catch {
        recorder.events.append("outer-wrong-error")
    }
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetValueCancellationProbe()
}
