@MainActor
func detachedOperationArgumentProbe() async -> String {
    let first = Task.detached(
        priority: .background,
        operation: {
            await Task.yield()
        })
    let second = Task.detached(
        priority: .utility,
        operation: {
            await Task.yield()
        })

    await first.value
    await second.value
    return "yielded:2"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedOperationArgumentProbe()
}
