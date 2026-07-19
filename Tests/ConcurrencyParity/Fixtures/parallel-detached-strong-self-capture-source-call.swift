func physicalStrongSelfCaptureIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalStrongSelfCaptureSourceCallProbe: @unchecked Sendable {
    private var observation = ""

    func registerDefaults() async {
        let before = physicalStrongSelfCaptureIsolation()
        await Task.yield()
        let after = physicalStrongSelfCaptureIsolation()
        await record("strong:\(before)|\(after)")
    }

    func launch() {
        Task.detached(priority: .userInitiated) { [self] in
            await self.registerDefaults()
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

func parallelDetachedStrongSelfCaptureSourceCallProbe() async -> String {
    let probe = PhysicalStrongSelfCaptureSourceCallProbe()
    probe.launch()
    return await probe.result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedStrongSelfCaptureSourceCallProbe()
}
