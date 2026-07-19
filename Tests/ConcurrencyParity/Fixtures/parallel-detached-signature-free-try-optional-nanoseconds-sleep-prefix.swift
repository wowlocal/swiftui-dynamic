@MainActor
final class PhysicalSignatureFreeNanosecondsSleepPrefixRecorder:
    @unchecked Sendable
{
    private var observations: [String] = []

    func submit(_ input: String) {
        observations.append("\(input):\(Task.isCancelled)")
    }

    func output() -> String {
        observations.joined(separator: ",")
    }

    func probe() async -> String {
        let completed = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 0)
            await MainActor.run {
                self.submit("completed")
            }
        }
        await completed.value

        let cancelled = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await MainActor.run {
                self.submit("cancelled")
            }
        }
        cancelled.cancel()
        await cancelled.value

        return "\(output())|\(completed.isCancelled):\(cancelled.isCancelled)"
    }
}

@MainActor
func parallelDetachedSignatureFreeTryOptionalNanosecondsSleepPrefixProbe()
    async -> String
{
    await PhysicalSignatureFreeNanosecondsSleepPrefixRecorder().probe()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedSignatureFreeTryOptionalNanosecondsSleepPrefixProbe()
}
