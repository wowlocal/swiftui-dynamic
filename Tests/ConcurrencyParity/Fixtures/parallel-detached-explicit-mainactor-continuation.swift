@MainActor
final class PhysicalDetachedExplicitMainActorRecorder: @unchecked Sendable {
    private var observations: [String] = []

    func submit(_ input: String) {
        observations.append("\(input):\(Task.isCancelled)")
    }

    func output() -> String {
        observations.joined(separator: ",")
    }

    func probe() async -> String {
        let completed = Task.detached(priority: .utility) { @MainActor in
            self.submit("completed")
        }
        await completed.value

        let cancelled = Task.detached(priority: .utility) { @MainActor in
            self.submit("cancelled")
        }
        cancelled.cancel()
        await cancelled.value

        return "\(output())|\(completed.isCancelled):\(cancelled.isCancelled)"
    }
}

@MainActor
func parallelDetachedExplicitMainActorContinuationProbe() async -> String {
    await PhysicalDetachedExplicitMainActorRecorder().probe()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedExplicitMainActorContinuationProbe()
}
