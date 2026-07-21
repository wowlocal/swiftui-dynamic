@MainActor
func unsafeContinuationValueResumeProbe() async -> String {
    let value: Int = await withUnsafeContinuation(
        isolation: MainActor.shared
    ) { continuation in
        continuation.resume(returning: 33)
    }
    return "value:\(value)"
}

@MainActor
func parityNativeOutput() async -> String {
    await unsafeContinuationValueResumeProbe()
}
