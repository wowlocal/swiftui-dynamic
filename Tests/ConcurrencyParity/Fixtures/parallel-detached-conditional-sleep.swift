@MainActor
func parallelDetachedConditionalSleep(_ slow: Bool) async -> String {
    do {
        try await Task.detached {
            try await Task.sleep(
                for: slow ? .seconds(0) : .milliseconds(1))
        }.value
        return slow ? "slow" : "fast"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func parallelDetachedConditionalSleepCancellation() async -> String {
    let slow = true
    let task = Task.detached {
        try await Task.sleep(
            for: slow ? .seconds(30) : .milliseconds(1))
    }
    task.cancel()
    do {
        try await task.value
        return "unexpected-value"
    } catch is CancellationError {
        return "cancelled:\(task.isCancelled)"
    } catch {
        return "unexpected-error"
    }
}

@MainActor
func parallelDetachedConditionalSleepParityProbe() async -> String {
    let slow = await parallelDetachedConditionalSleep(true)
    let fast = await parallelDetachedConditionalSleep(false)
    let cancellation = await parallelDetachedConditionalSleepCancellation()
    return "\(slow):\(fast)|\(cancellation)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelDetachedConditionalSleepParityProbe()
}
