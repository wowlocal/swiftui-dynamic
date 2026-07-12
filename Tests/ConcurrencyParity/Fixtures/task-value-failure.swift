enum TaskValueProbeError: Error {
    case failed
}

@MainActor
func taskValueFailureProbe() async -> String {
    let handle = Task {
        let marker = await parityYield("failure")
        if marker == "failure" {
            throw TaskValueProbeError.failed
        }
        return "wrong"
    }
    do {
        _ = try await handle.value
        return "missed"
    } catch {
        return "caught"
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskValueFailureProbe()
}
