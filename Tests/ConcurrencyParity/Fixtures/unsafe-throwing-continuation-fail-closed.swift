@MainActor
func unsafeThrowingContinuationFailClosedProbe() async throws -> String {
    let value: Int = try await withUnsafeThrowingContinuation(
        isolation: MainActor.shared
    ) { continuation in
        continuation.resume(returning: 44)
    }
    return "value:\(value)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await unsafeThrowingContinuationFailClosedProbe()
}
