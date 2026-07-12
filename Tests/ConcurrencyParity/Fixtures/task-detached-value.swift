@MainActor
func taskDetachedValueProbe() async -> String {
    let handle = Task.detached {
        await parityYield("detached")
    }
    return await handle.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskDetachedValueProbe()
}
