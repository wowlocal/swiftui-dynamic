@MainActor
func parallelDetachedYieldProbe() async -> String {
    await Task.detached(priority: .background) {
        await Task.yield()
    }.value
    await Task.detached(priority: .background) {
        await Task.yield()
    }.value
    return "yielded:2"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await parallelDetachedYieldProbe()
}
