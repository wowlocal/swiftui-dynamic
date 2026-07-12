enum TaskResultProbeError: Error {
    case failed
}

@MainActor
func taskResultProbe() async -> String {
    let success = Task {
        await parityWaitTaskValueGate()
        return "value"
    }
    Task {
        await parityAwaitTaskValueGateStarted()
        parityOpenTaskValueGate()
    }

    let successDescription: String
    switch await success.result {
    case .success(let value):
        successDescription = "success:" + value
    case .failure:
        successDescription = "unexpected-failure"
    }

    let failure = Task {
        let marker = await parityYield("failure")
        if marker == "failure" {
            throw TaskResultProbeError.failed
        }
        return "wrong"
    }
    let failureResult = await failure.result
    let failureDescription: String
    switch failureResult {
    case .success:
        failureDescription = "unexpected-success"
    case .failure:
        failureDescription = "failure"
    }

    let getDescription: String
    do {
        _ = try failureResult.get()
        getDescription = "get-missed"
    } catch {
        getDescription = "get-caught"
    }

    return successDescription + "," + failureDescription + "," + getDescription
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskResultProbe()
}
