func physicalConcurrentSourceCallIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

@MainActor
final class PhysicalConcurrentSourceCallProbe {
    private var observation = ""

    private func record(_ value: String) {
        observation = value
    }

    @concurrent
    nonisolated func compute(id: Int, run: Int) async -> String {
        await Task.yield()
        let isolation = physicalConcurrentSourceCallIsolation()
        await record("\(id + run):\(isolation)")
        return "\(id):\(run)"
    }

    func run() async -> String {
        let value = await Task.detached(priority: .utility) {
            await self.compute(id: 7, run: 11)
        }.value
        return "\(value)|\(observation)"
    }
}

@MainActor
func parallelDetachedConcurrentSourceCallProbe() async -> String {
    await PhysicalConcurrentSourceCallProbe().run()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelDetachedConcurrentSourceCallProbe()
}
