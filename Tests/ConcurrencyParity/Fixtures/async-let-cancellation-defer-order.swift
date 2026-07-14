import Foundation

@MainActor
final class AsyncLetCancellationDeferOrderRecorder {
    var events: [String] = []
    var childStarted = false
    var ownerWaiting = false
    var scopeExitReached = false
    var releaseChild = false
    var childCaughtCancellation = false
    var ownerCaughtCancellation = false
    var ownerWasCancelled = false
}

@MainActor
func cancellationDeferOrderChild(
    _ recorder: AsyncLetCancellationDeferOrderRecorder
) async -> String {
    recorder.childStarted = true
    do {
        try await Task.sleep(for: .seconds(30))
    } catch is CancellationError {
        recorder.childCaughtCancellation = true
        while !recorder.releaseChild {
            await Task.yield()
        }
        recorder.events.append("child-complete")
    } catch {
        recorder.events.append("wrong-child-error")
    }
    return "unused"
}

@MainActor
func cancelWithDeferBeforeAsyncLet(
    _ recorder: AsyncLetCancellationDeferOrderRecorder
) async -> String {
    defer {
        recorder.events.append("defer")
    }
    async let unused = cancellationDeferOrderChild(recorder)
    while !recorder.childStarted {
        await Task.yield()
    }
    recorder.ownerWaiting = true
    do {
        try await Task.sleep(for: .seconds(30))
    } catch is CancellationError {
        recorder.ownerCaughtCancellation = true
    } catch {
        recorder.events.append("wrong-owner-error")
    }
    recorder.ownerWasCancelled = Task.isCancelled
    recorder.scopeExitReached = true
    recorder.events.append("scope-exit")
    return "returned"
}

@MainActor
func cancelWithDeferAfterAsyncLet(
    _ recorder: AsyncLetCancellationDeferOrderRecorder
) async -> String {
    async let unused = cancellationDeferOrderChild(recorder)
    defer {
        recorder.events.append("defer")
    }
    while !recorder.childStarted {
        await Task.yield()
    }
    recorder.ownerWaiting = true
    do {
        try await Task.sleep(for: .seconds(30))
    } catch is CancellationError {
        recorder.ownerCaughtCancellation = true
    } catch {
        recorder.events.append("wrong-owner-error")
    }
    recorder.ownerWasCancelled = Task.isCancelled
    recorder.scopeExitReached = true
    recorder.events.append("scope-exit")
    return "returned"
}

@MainActor
func runCancellationDeferOrderVariant(
    deferBefore: Bool
) async -> String {
    let recorder = AsyncLetCancellationDeferOrderRecorder()
    let owner = Task {
        if deferBefore {
            return await cancelWithDeferBeforeAsyncLet(recorder)
        }
        return await cancelWithDeferAfterAsyncLet(recorder)
    }
    while !recorder.ownerWaiting {
        await Task.yield()
    }
    owner.cancel()
    while !recorder.scopeExitReached {
        await Task.yield()
    }
    recorder.releaseChild = true
    let value = await owner.value
    recorder.events.append(value)
    let cancellation = recorder.childCaughtCancellation
        && recorder.ownerCaughtCancellation
        && recorder.ownerWasCancelled
        && owner.isCancelled
        ? "cancelled"
        : "wrong-cancellation"
    return recorder.events.joined(separator: ",") + ":" + cancellation
}

@MainActor
func asyncLetCancellationDeferOrderProbe() async -> String {
    let before = await runCancellationDeferOrderVariant(deferBefore: true)
    let after = await runCancellationDeferOrderVariant(deferBefore: false)
    return before + "|" + after
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetCancellationDeferOrderProbe()
}
