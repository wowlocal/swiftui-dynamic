actor PhysicalActorSourceCallProbe {
    private var observation = ""

    init() {
        Task.detached(priority: .utility) {
            await self.record()
        }
    }

    private func record() {
        observation = "actor|R"
    }

    func result() async -> String {
        while observation.isEmpty {
            await Task.yield()
        }
        return observation
    }
}

func parallelDetachedActorSourceCallProbe() async -> String {
    await PhysicalActorSourceCallProbe().result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedActorSourceCallProbe()
}
