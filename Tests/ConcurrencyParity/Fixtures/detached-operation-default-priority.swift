@MainActor
func detachedOperationDefaultPriorityProbe() async -> String {
    let first = Task.detached(
        operation: {
            await Task.yield()
        })
    let second = Task.detached(
        operation: {
            await Task.yield()
        })

    await first.value
    await second.value
    return "defaulted:2"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedOperationDefaultPriorityProbe()
}
