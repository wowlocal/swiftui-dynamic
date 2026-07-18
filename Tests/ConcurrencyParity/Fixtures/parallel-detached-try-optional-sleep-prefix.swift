actor PhysicalTryOptionalSleepPrefixRecorder {
    private var observations: [String] = []

    func submit(_ input: String) {
        observations.append("\(input):\(Task.isCancelled)")
    }

    func output() -> String {
        observations.joined(separator: ",")
    }
}

func parallelDetachedTryOptionalSleepPrefixProbe() async -> String {
    let recorder = PhysicalTryOptionalSleepPrefixRecorder()

    let completed = Task.detached(priority: .userInitiated) {
        try? await Task.sleep(for: .milliseconds(0))
        await recorder.submit("completed")
    }
    await completed.value

    let cancelled = Task.detached(priority: .userInitiated) {
        try? await Task.sleep(for: .seconds(30))
        await recorder.submit("cancelled")
    }
    cancelled.cancel()
    await cancelled.value

    let output = await recorder.output()
    return "\(output)|\(completed.isCancelled):\(cancelled.isCancelled)"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedTryOptionalSleepPrefixProbe()
}
