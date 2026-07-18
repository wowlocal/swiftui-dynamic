@MainActor
func detachedContextualTaskStaticMemberProbe() async -> String {
    let task: Task<String, Never> = .detached(priority: .userInitiated) {
        let before = parityCurrentIsolationMatches(MainActor.shared)
        await Task.yield()
        let after = parityCurrentIsolationMatches(MainActor.shared)
        return "\(before)|\(after)"
    }
    return await task.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedContextualTaskStaticMemberProbe()
}
