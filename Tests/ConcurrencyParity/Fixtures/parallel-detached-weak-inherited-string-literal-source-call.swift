func physicalWeakInheritedStringLiteralIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalWeakInheritedStringLiteralProbe: @unchecked Sendable {
    private var observation = ""

    func restartProcessingIfQueueHasPendingWork(context: String) async {
        let before = physicalWeakInheritedStringLiteralIsolation()
        await Task.yield()
        let after = physicalWeakInheritedStringLiteralIsolation()
        await record("\(context):\(before)|\(after)")
    }

    func launch() -> Task<Void?, Never> {
        Task.detached(priority: .background) { [weak self] in
            await self?.restartProcessingIfQueueHasPendingWork(
                context: "timeout")
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

func parallelDetachedWeakInheritedStringLiteralSourceCallProbe() async
    -> String
{
    let probe = PhysicalWeakInheritedStringLiteralProbe()
    let result: Void? = await probe.launch().value
    let observation = await probe.result()
    return "\(observation)#\(result == nil ? "nil" : "some")"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedWeakInheritedStringLiteralSourceCallProbe()
}
