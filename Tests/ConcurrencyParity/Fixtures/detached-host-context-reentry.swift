@MainActor
func detachedHostContextProbe() async throws -> String {
    let inheritance = await parityDetachedInheritance()
    let rebound = try await parityDetachedReentry {
        await parityCheckContext()
    }
    return inheritance + "," + rebound
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await detachedHostContextProbe()
}
