@globalActor
actor PhysicalSourceCallGlobalActor {
    static let shared = PhysicalSourceCallGlobalActor()
}

final class PhysicalCustomGlobalActorSourceCallProbe: @unchecked Sendable {
    private var observation = ""
    private var finished = false

    @PhysicalSourceCallGlobalActor
    private func createSystemDirectories() async {
        observation = parityCurrentIsolationMatches(
            PhysicalSourceCallGlobalActor.shared)
        await Task.yield()
        observation += "|" + parityCurrentIsolationMatches(
            PhysicalSourceCallGlobalActor.shared)
        finished = true
    }

    func launch() {
        Task.detached(priority: .utility) {
            await self.createSystemDirectories()
        }
    }

    @PhysicalSourceCallGlobalActor
    func result() async -> String {
        while !finished {
            await Task.yield()
        }
        return observation
    }
}

func parallelDetachedCustomGlobalActorSourceCallProbe() async -> String {
    let probe = PhysicalCustomGlobalActorSourceCallProbe()
    probe.launch()
    return await probe.result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedCustomGlobalActorSourceCallProbe()
}
