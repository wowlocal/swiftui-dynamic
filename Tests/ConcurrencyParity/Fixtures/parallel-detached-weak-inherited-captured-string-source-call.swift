func physicalWeakInheritedCapturedStringIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalWeakInheritedCapturedStringProbe: @unchecked Sendable {
    private var observation = ""

    func updateMentions(for newText: String) async {
        let before = physicalWeakInheritedCapturedStringIsolation()
        await Task.yield()
        let after = physicalWeakInheritedCapturedStringIsolation()
        await record("\(newText):\(before)|\(after)")
    }

    func launch(newText: String) -> Task<Void?, Never> {
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.updateMentions(for: newText)
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

func parallelDetachedWeakInheritedCapturedStringSourceCallProbe() async
    -> String
{
    let probe = PhysicalWeakInheritedCapturedStringProbe()
    let result: Void? = await probe.launch(newText: "session-message").value
    let observation = await probe.result()
    return "\(observation)#\(result == nil ? "nil" : "some")"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedWeakInheritedCapturedStringSourceCallProbe()
}
