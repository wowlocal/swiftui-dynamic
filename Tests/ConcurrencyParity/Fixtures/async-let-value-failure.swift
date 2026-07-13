enum AsyncLetValueFailure: Error {
    case failed
}

@MainActor
func failingAsyncLetChild() async throws -> String {
    let marker = await parityYield("failure")
    if marker == "failure" {
        throw AsyncLetValueFailure.failed
    }
    return "wrong"
}

@MainActor
func asyncLetValueFailureProbe() async -> String {
    async let value = try failingAsyncLetChild()
    do {
        _ = try await value
        return "missed"
    } catch {
        return "caught"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetValueFailureProbe()
}
