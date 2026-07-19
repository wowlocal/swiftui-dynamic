@MainActor
final class PhysicalMainActorBooleanSourceCallProbe {
    private var observation = ""

    func apply(_ enabled: Bool) async -> String {
        await Task.yield()
        observation = observation + (enabled ? "T" : "F")
        return enabled ? "on" : "off"
    }

    func run() async -> String {
        let enabled = await Task.detached(priority: .utility) {
            await self.apply(true)
        }.value
        let disabled = await Task.detached(priority: .utility) {
            await self.apply(false)
        }.value
        return enabled + ":" + disabled + "|" + observation
    }
}

@MainActor
func parallelDetachedMainActorBooleanSourceCallProbe() async -> String {
    await PhysicalMainActorBooleanSourceCallProbe().run()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelDetachedMainActorBooleanSourceCallProbe()
}
