@MainActor
func asyncTryAwaitConditionalOptional() async throws -> String? {
    await Task.yield()
    return nil
}

@MainActor
func asyncTryAwaitConditionalProbe() async -> String {
    do {
        return try await asyncTryAwaitConditionalOptional() == nil
            ? "nil"
            : "value"
    } catch {
        return "error"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncTryAwaitConditionalProbe()
}
