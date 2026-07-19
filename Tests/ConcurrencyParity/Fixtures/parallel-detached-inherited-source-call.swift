func physicalInheritedSourceCallIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalInheritedSourceCallProbe: @unchecked Sendable {
    private var observation = ""

    func refreshWebServerState() async {
        let before = physicalInheritedSourceCallIsolation()
        await Task.yield()
        let after = physicalInheritedSourceCallIsolation()
        await record("\(before)|\(after)")
    }

    func launch() {
        Task.detached(priority: .utility) {
            await self.refreshWebServerState()
        }
    }

    @MainActor
    private func record(_ value: String) {
        observation = value
    }

    @MainActor
    func result() async -> String {
        while observation.isEmpty {
            await Task.yield()
        }
        return observation
    }
}

func parallelDetachedInheritedSourceCallProbe() async -> String {
    let probe = PhysicalInheritedSourceCallProbe()
    probe.launch()
    return await probe.result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedInheritedSourceCallProbe()
}
