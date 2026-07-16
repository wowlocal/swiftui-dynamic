import _Concurrency

nonisolated func continuationEntryPointsProbe() async throws -> String {
    let checked: Int = await withCheckedContinuation(
        isolation: MainActor.shared,
        function: #function
    ) { continuation in
        MainActor.assertIsolated()
        continuation.resume(returning: 11)
    }

    let checkedThrowing: Int = try await withCheckedThrowingContinuation(
        isolation: MainActor.shared,
        function: #function
    ) { continuation in
        MainActor.assertIsolated()
        continuation.resume(returning: 22)
    }

    let unsafe: Int = await withUnsafeContinuation(
        isolation: MainActor.shared
    ) { continuation in
        MainActor.assertIsolated()
        continuation.resume(returning: 33)
    }

    let unsafeThrowing: Int = try await withUnsafeThrowingContinuation(
        isolation: MainActor.shared
    ) { continuation in
        MainActor.assertIsolated()
        continuation.resume(returning: 44)
    }

    return "checked:\(checked)"
        + "|checkedThrowing:\(checkedThrowing)"
        + "|unsafe:\(unsafe)"
        + "|unsafeThrowing:\(unsafeThrowing)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await continuationEntryPointsProbe()
}
