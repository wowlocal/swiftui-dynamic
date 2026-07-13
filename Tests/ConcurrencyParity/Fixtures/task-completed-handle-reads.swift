enum TaskCompletedHandleReadError: Error {
    case failed
}

@MainActor
final class TaskCompletedHandleReadRecorder {
    var success: Task<String, Never>?
    var failure: Task<String, any Error>?
    var output = ""
}

@MainActor
func startTaskCompletedHandleReadProbe() async
    -> TaskCompletedHandleReadRecorder {
    let recorder = TaskCompletedHandleReadRecorder()
    let success = Task {
        await parityYield("value")
    }
    recorder.success = success

    // The first read establishes completion. Every later read is against the
    // already-completed handle and must reproduce the stored logical outcome.
    let firstValue = await success.value
    let secondValue = await success.value
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
            throw TaskCompletedHandleReadError.failed
        }
        return "unexpected-value"
    }
    recorder.failure = failure

    let firstFailure = await failure.result
    let firstFailureDescription: String
    switch firstFailure {
    case .success:
        firstFailureDescription = "unexpected-success"
    case .failure:
        firstFailureDescription = "failure"
    }

    let secondFailure = await failure.result
    let secondFailureDescription: String
    switch secondFailure {
    case .success:
        secondFailureDescription = "unexpected-success"
    case .failure:
        secondFailureDescription = "failure"
    }

    let getDescription: String
    do {
        _ = try secondFailure.get()
        getDescription = "get-missed"
    } catch {
        getDescription = "get-caught"
    }

    recorder.output = firstValue + "," + secondValue + ","
        + successDescription + "," + firstFailureDescription + ","
        + secondFailureDescription + "," + getDescription
    return recorder
}

@MainActor
func taskCompletedHandleReadProbe() async -> String {
    let recorder = await startTaskCompletedHandleReadProbe()
    return recorder.output
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskCompletedHandleReadProbe()
}
