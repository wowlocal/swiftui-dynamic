enum CheckedThrowingContinuationProbeError: Error {
    case failed
}

nonisolated func checkedThrowingContinuationValueErrorProbe() async -> String {
    let value: Int
    do {
        value = try await withCheckedThrowingContinuation(
            isolation: nil,
            function: #function
        ) { continuation in
            Task.detached {
                await Task.yield()
                continuation.resume(returning: 23)
            }
        }
    } catch {
        return "unexpected-value-error"
    }

    let errorResult: String
    do {
        let _: Int = try await withCheckedThrowingContinuation(
            isolation: nil,
            function: #function
        ) { continuation in
            Task.detached {
                await Task.yield()
                continuation.resume(
                    throwing: CheckedThrowingContinuationProbeError.failed)
            }
        }
        errorResult = "missing-error"
    } catch CheckedThrowingContinuationProbeError.failed {
        errorResult = "failed"
    } catch {
        errorResult = "unexpected-error"
    }

    return "value:\(value)|error:\(errorResult)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await checkedThrowingContinuationValueErrorProbe()
}
