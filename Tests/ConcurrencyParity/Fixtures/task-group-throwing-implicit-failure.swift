enum ThrowingTaskGroupImplicitFailure: Error {
    case failed
}

@MainActor
final class ThrowingTaskGroupImplicitFailureRecorder {
    var events: [String] = []
}

@MainActor
func taskGroupThrowingImplicitFailureChild(
    _ recorder: ThrowingTaskGroupImplicitFailureRecorder
) async throws -> String {
    recorder.events.append("child-start")
    await parityWaitTaskValueGate()
    recorder.events.append("child-failed")
    throw ThrowingTaskGroupImplicitFailure.failed
}

@MainActor
func taskGroupThrowingImplicitFailureProbe() async -> String {
    let recorder = ThrowingTaskGroupImplicitFailureRecorder()
    let value = await withThrowingTaskGroup(
        of: String.self
    ) { group in
        group.addTask {
            try await taskGroupThrowingImplicitFailureChild(recorder)
        }
        await parityAwaitTaskValueGateStarted()
        recorder.events.append("body-return")
        parityOpenTaskValueGate()
        return "body-value"
    }
    recorder.events.append("scope-return-" + value)
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupThrowingImplicitFailureProbe()
}
