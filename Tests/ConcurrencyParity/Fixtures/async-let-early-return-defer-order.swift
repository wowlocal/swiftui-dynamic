import Foundation

@MainActor
final class AsyncLetEarlyReturnDeferOrderRecorder {
    var events: [String] = []
    var childStarted = false
}

@MainActor
func earlyReturnDeferOrderChild(
    _ recorder: AsyncLetEarlyReturnDeferOrderRecorder
) async -> String {
    recorder.events.append("child-start")
    recorder.childStarted = true
    do {
        try await Task.sleep(for: .seconds(30))
        recorder.events.append("child-finished")
    } catch is CancellationError {
        recorder.events.append("child-cancelled")
    } catch {
        recorder.events.append("wrong-child-error")
    }
    return "unused"
}

@MainActor
func returnWithDeferBeforeAsyncLet(
    _ recorder: AsyncLetEarlyReturnDeferOrderRecorder
) async -> String {
    defer {
        recorder.events.append("defer")
    }
    async let unused = earlyReturnDeferOrderChild(recorder)
    while !recorder.childStarted {
        await Task.yield()
    }
    recorder.events.append("early-return")
    return "returned"
}

@MainActor
func returnWithDeferAfterAsyncLet(
    _ recorder: AsyncLetEarlyReturnDeferOrderRecorder
) async -> String {
    async let unused = earlyReturnDeferOrderChild(recorder)
    defer {
        recorder.events.append("defer")
    }
    while !recorder.childStarted {
        await Task.yield()
    }
    recorder.events.append("early-return")
    return "returned"
}

@MainActor
func earlyReturnDeferBeforeAsyncLetProbe() async -> String {
    let recorder = AsyncLetEarlyReturnDeferOrderRecorder()
    let value = await returnWithDeferBeforeAsyncLet(recorder)
    recorder.events.append(value)
    return recorder.events.joined(separator: ",")
}

@MainActor
func earlyReturnDeferAfterAsyncLetProbe() async -> String {
    let recorder = AsyncLetEarlyReturnDeferOrderRecorder()
    let value = await returnWithDeferAfterAsyncLet(recorder)
    recorder.events.append(value)
    return recorder.events.joined(separator: ",")
}

@MainActor
func asyncLetEarlyReturnDeferOrderProbe() async -> String {
    let before = await earlyReturnDeferBeforeAsyncLetProbe()
    let after = await earlyReturnDeferAfterAsyncLetProbe()
    return before + "|" + after
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetEarlyReturnDeferOrderProbe()
}
