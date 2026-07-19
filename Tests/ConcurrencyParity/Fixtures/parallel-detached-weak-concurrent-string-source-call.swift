func physicalWeakConcurrentStringSourceCallIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalWeakConcurrentStringSourceCallProbe: @unchecked Sendable {
    private var observation = ""

    @concurrent
    nonisolated func loadImageAndCacheIt(imagePath: String) async {
        let before = physicalWeakConcurrentStringSourceCallIsolation()
        await Task.yield()
        let after = physicalWeakConcurrentStringSourceCallIsolation()
        await record("\(imagePath):\(before)|\(after)")
    }

    func launch(imagePath: String) -> Task<Void?, Never> {
        Task.detached(priority: .high) { [weak self] in
            await self?.loadImageAndCacheIt(imagePath: imagePath)
        }
    }

    @MainActor
    private func record(_ value: String) {
        observation = value
    }

    @MainActor
    func result() -> String {
        observation
    }
}

func parallelDetachedWeakConcurrentStringSourceCallProbe() async -> String {
    let probe = PhysicalWeakConcurrentStringSourceCallProbe()
    let result: Void? = await probe.launch(imagePath: "cover-cache").value
    let observation = await probe.result()
    return "\(observation)#\(result == nil ? "nil" : "some")"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedWeakConcurrentStringSourceCallProbe()
}
