@MainActor
func paritySourceProvenanceAfterSuspension() async -> String {
    let callback: () async -> Int = {
        await Task.yield()
        return #line
    }
    return String(await callback())
}

@MainActor
func parityNativeOutput() async throws -> String {
    await paritySourceProvenanceAfterSuspension()
}
