import Foundation

enum ExtractIsolationProbeError: Error {
    case mustNotRun
}

nonisolated func extractIsolationPlainOperation(
    _ value: Int,
    label: String
) async throws(ExtractIsolationProbeError) -> String {
    throw .mustNotRun
}

@concurrent
nonisolated func extractIsolationConcurrentOperation() async -> Int {
    preconditionFailure("extractIsolation executed its argument")
}

@available(*, deprecated)
nonisolated func extractIsolationNonisolatedProbe() -> String {
    let plain = extractIsolation(extractIsolationPlainOperation)
    let concurrent = extractIsolation(extractIsolationConcurrentOperation)
    return "plain:\(plain == nil)|concurrent:\(concurrent == nil)"
}

@available(*, deprecated)
@MainActor
func parityNativeOutput() async throws -> String {
    extractIsolationNonisolatedProbe()
}
