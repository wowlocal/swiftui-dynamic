@MainActor
func unsafeContinuationFailClosedProbe() async -> String {
    let value: Int = await withUnsafeContinuation(
        isolation: MainActor.shared
    ) { continuation in
        continuation.resume(returning: 33)
    }
    return "value:\(value)"
}

@MainActor
func parityNativeOutput() async -> String {
    await unsafeContinuationFailClosedProbe()
}
