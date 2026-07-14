@MainActor
final class AsyncLetParentCancellationRecorder {
    nonisolated(unsafe) var events: [String] = []
    var parentWaiting = false
}

@MainActor
func parentCancellationAsyncLetChild(
    _ recorder: AsyncLetParentCancellationRecorder
) async -> String {
    do {
        try await withTaskCancellationHandler(operation: {
            recorder.events.append("child-start")
            try await parityWaitForever()
            recorder.events.append("child-wrong-finish")
        }, onCancel: {
            recorder.events.append("child-cancel-requested")
        })
    } catch is CancellationError {
        recorder.events.append("child-observed-cancellation")
    } catch {
        recorder.events.append("child-wrong-error")
    }
    recorder.events.append("child-finished")
    return "unused"
}

@MainActor
func parentCancellationAsyncLetOwner(
    _ recorder: AsyncLetParentCancellationRecorder
) async {
    async let unused = parentCancellationAsyncLetChild(recorder)
    await parityAwaitWaitStarted()
    recorder.events.append("parent-wait")
    recorder.parentWaiting = true
    do {
        try await parityWaitForever()
        recorder.events.append("parent-wrong-finish")
    } catch is CancellationError {
        recorder.events.append("parent-observed-cancellation")
    } catch {
        recorder.events.append("parent-wrong-error")
    }
    recorder.events.append("owner-exit")
}

@MainActor
func asyncLetParentCancellationScopeExitProbe() async -> String {
    let recorder = AsyncLetParentCancellationRecorder()
    let parent = Task {
        await parentCancellationAsyncLetOwner(recorder)
    }
    while !recorder.parentWaiting {
        await Task.yield()
    }
    recorder.events.append("cancel-issued")
    parent.cancel()
    await parent.value
    recorder.events.append("parent-finished")
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetParentCancellationScopeExitProbe()
}
