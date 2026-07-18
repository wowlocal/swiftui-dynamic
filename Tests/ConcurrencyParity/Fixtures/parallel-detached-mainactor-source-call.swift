@MainActor
final class PhysicalMainActorSourceCallProbe {
    private var updateCount = 0
    private var observedCancellation = false

    private func update() async {
        await Task.yield()
        updateCount += 1
    }

    private func observeCancellation() async {
        await Task.yield()
        observedCancellation = Task.isCancelled
    }

    func run() async -> String {
        await Task.detached(priority: .background) {
            await self.update()
        }.value

        let cancelled = Task.detached(priority: .background) {
            await self.observeCancellation()
        }
        cancelled.cancel()
        await cancelled.value
        return "\(updateCount):\(observedCancellation)"
    }
}

@MainActor
func parallelDetachedMainActorSourceCallProbe() async -> String {
    await PhysicalMainActorSourceCallProbe().run()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelDetachedMainActorSourceCallProbe()
}
