@MainActor
func taskStaticGeneratedSurfaceProbe() async throws -> String {
    let state = Task.isCancelled ? "cancelled" : "active"
    try Task.checkCancellation()
    await Task.yield()
    try await Task.sleep(nanoseconds: 0)
    let detached = Task.detached { "detached" }
    return state + ":" + (await detached.value)
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await taskStaticGeneratedSurfaceProbe()
}
