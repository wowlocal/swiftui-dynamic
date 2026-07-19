struct ShadowTaskYieldReceiver: Sendable {
    func yield() async -> String {
        "source"
    }
}

@MainActor
func parallelShadowedTaskYieldProbe() async -> String {
    let spawn = {
        (operation: @escaping @Sendable () async -> String) in
        Task.detached(operation: operation)
    }
    return await {
        let Task = ShadowTaskYieldReceiver()
        return await spawn {
            await Task.yield()
        }.value
    }()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelShadowedTaskYieldProbe()
}
