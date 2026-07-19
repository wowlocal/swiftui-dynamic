func physicalInheritedStringSourceCallIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalInheritedStringSourceCallProbe: @unchecked Sendable {
    private var observation = ""

    func sendNotificationForNewCID(cid: String) async {
        let before = physicalInheritedStringSourceCallIsolation()
        await Task.yield()
        let after = physicalInheritedStringSourceCallIsolation()
        await record("\(cid):\(before)|\(after)")
    }

    func launch(cid: String) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            await self.sendNotificationForNewCID(cid: cid)
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

func parallelDetachedInheritedStringSourceCallProbe() async -> String {
    let probe = PhysicalInheritedStringSourceCallProbe()
    let cid = "bafy-planet"
    await probe.launch(cid: cid).value
    return await probe.result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedInheritedStringSourceCallProbe()
}
