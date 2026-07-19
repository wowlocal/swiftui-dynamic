func physicalWeakInheritedStringArrayIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

final class PhysicalWeakInheritedStringArrayProbe: @unchecked Sendable {
    private var observation = ""

    func reload(_ additionalPaths: [String]) async {
        let before = physicalWeakInheritedStringArrayIsolation()
        await Task.yield()
        let after = physicalWeakInheritedStringArrayIsolation()
        let paths = additionalPaths[0] + "," + additionalPaths[1]
        await record("\(paths):\(before)|\(after)")
    }

    func launch(additionalPaths: [String]) -> Task<Void?, Never> {
        Task.detached { [weak self] in
            await self?.reload(additionalPaths)
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

func parallelDetachedWeakInheritedStringArraySourceCallProbe() async
    -> String
{
    let probe = PhysicalWeakInheritedStringArrayProbe()
    let paths = ["Applications", "WebApps"]
    let result: Void? = await probe.launch(additionalPaths: paths).value
    let observation = await probe.result()
    return "\(observation)#\(result == nil ? "nil" : "some")"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedWeakInheritedStringArraySourceCallProbe()
}
