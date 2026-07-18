func physicalWeakSelfCaptureIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalWeakSelfCaptureSourceCallProbe: @unchecked Sendable {
    private var observation = ""

    func processQueue() async {
        let before = physicalWeakSelfCaptureIsolation()
        await Task.yield()
        let after = physicalWeakSelfCaptureIsolation()
        await record("weak:\(before)|\(after)")
    }

    func launch() {
        Task.detached(priority: .background) { [weak self] in
            await self?.processQueue()
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

func parallelDetachedWeakSelfSourceCallProbe() async -> String {
    let probe = PhysicalWeakSelfCaptureSourceCallProbe()
    probe.launch()
    return await probe.result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedWeakSelfSourceCallProbe()
}
