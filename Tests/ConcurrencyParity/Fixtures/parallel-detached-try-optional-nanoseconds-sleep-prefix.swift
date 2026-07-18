@MainActor
final class PhysicalTryOptionalNanosecondsSleepPrefixRecorder {
    private var observations: [String] = []

    func submit(_ input: String) {
        observations.append("\(input):\(Task.isCancelled)")
    }

    func output() -> String {
        observations.joined(separator: ",")
    }

    func probe() async -> String {
        let completed = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 0)
            await MainActor.run {
                self?.submit("completed")
            }
        }
        await completed.value

        let cancelled = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await MainActor.run {
                self?.submit("cancelled")
            }
        }
        cancelled.cancel()
        await cancelled.value

        return "\(output())|\(completed.isCancelled):\(cancelled.isCancelled)"
    }
}

@MainActor
private var retainedPhysicalTryOptionalNanosecondsSleepPrefixRecorder:
    PhysicalTryOptionalNanosecondsSleepPrefixRecorder?

@MainActor
func parallelDetachedTryOptionalNanosecondsSleepPrefixProbe() async -> String {
    let recorder = PhysicalTryOptionalNanosecondsSleepPrefixRecorder()
    retainedPhysicalTryOptionalNanosecondsSleepPrefixRecorder = recorder
    let output = await recorder.probe()
    retainedPhysicalTryOptionalNanosecondsSleepPrefixRecorder = nil
    return output
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedTryOptionalNanosecondsSleepPrefixProbe()
}
