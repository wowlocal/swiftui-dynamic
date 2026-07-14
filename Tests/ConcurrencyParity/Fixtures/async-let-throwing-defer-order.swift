import Foundation

enum AsyncLetThrowingDeferOrderError: Error {
    case failed
}

@MainActor
final class AsyncLetThrowingDeferOrderRecorder {
    var events: [String] = []
    var childStarted = false
}

@MainActor
func throwingDeferOrderChild(
    _ recorder: AsyncLetThrowingDeferOrderRecorder
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
func throwWithDeferBeforeAsyncLet(
    _ recorder: AsyncLetThrowingDeferOrderRecorder
) async throws {
    defer {
        recorder.events.append("defer")
    }
    async let unused = throwingDeferOrderChild(recorder)
    while !recorder.childStarted {
        await Task.yield()
    }
    recorder.events.append("scope-throw")
    throw AsyncLetThrowingDeferOrderError.failed
}

@MainActor
func throwWithDeferAfterAsyncLet(
    _ recorder: AsyncLetThrowingDeferOrderRecorder
) async throws {
    async let unused = throwingDeferOrderChild(recorder)
    defer {
        recorder.events.append("defer")
    }
    while !recorder.childStarted {
        await Task.yield()
    }
    recorder.events.append("scope-throw")
    throw AsyncLetThrowingDeferOrderError.failed
}

@MainActor
func throwingDeferBeforeAsyncLetProbe() async -> String {
    let recorder = AsyncLetThrowingDeferOrderRecorder()
    do {
        try await throwWithDeferBeforeAsyncLet(recorder)
        recorder.events.append("missed")
    } catch AsyncLetThrowingDeferOrderError.failed {
        recorder.events.append("caught")
    } catch {
        recorder.events.append("wrong-error")
    }
    return recorder.events.joined(separator: ",")
}

@MainActor
func throwingDeferAfterAsyncLetProbe() async -> String {
    let recorder = AsyncLetThrowingDeferOrderRecorder()
    do {
        try await throwWithDeferAfterAsyncLet(recorder)
        recorder.events.append("missed")
    } catch AsyncLetThrowingDeferOrderError.failed {
        recorder.events.append("caught")
    } catch {
        recorder.events.append("wrong-error")
    }
    return recorder.events.joined(separator: ",")
}

@MainActor
func asyncLetThrowingDeferOrderProbe() async -> String {
    let before = await throwingDeferBeforeAsyncLetProbe()
    let after = await throwingDeferAfterAsyncLetProbe()
    return before + "|" + after
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetThrowingDeferOrderProbe()
}
