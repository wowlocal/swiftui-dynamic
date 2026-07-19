actor PhysicalWeakTryOptionalSleepPrefixRecorder {
    private var observations: [String] = []

    func submit(_ input: String) {
        observations.append("\(input):\(Task.isCancelled)")
    }

    func output() -> String {
        observations.joined(separator: ",")
    }

    func launchCompleted(groupID: String) -> Task<Void, Never> {
        Task.detached(priority: .medium) { [weak self] in
            try? await Task.sleep(for: .milliseconds(0))
            await self?.submit(groupID)
        }
    }

    func launchCancelled(groupID: String) -> Task<Void, Never> {
        Task.detached(priority: .medium) { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.submit(groupID)
        }
    }
}

func parallelDetachedWeakTryOptionalSleepPrefixProbe() async -> String {
    let recorder = PhysicalWeakTryOptionalSleepPrefixRecorder()

    let completed = await recorder.launchCompleted(groupID: "group-a")
    await completed.value

    let cancelled = await recorder.launchCancelled(groupID: "group-b")
    cancelled.cancel()
    await cancelled.value

    let output = await recorder.output()
    return "\(output)|\(completed.isCancelled):\(cancelled.isCancelled)"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedWeakTryOptionalSleepPrefixProbe()
}
