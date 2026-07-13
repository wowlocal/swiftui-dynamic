@MainActor
final class TaskSleepCancellationRecorder {
    var events: [String] = []
}

@MainActor
func taskSleepCancellationProbe() async -> String {
    let recorder = TaskSleepCancellationRecorder()
    let sleeper = Task {
        recorder.events.append("started")
        parityMarkSleepStarted()
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            recorder.events.append("completed")
        } catch is CancellationError {
            recorder.events.append("cancelled")
        } catch {
            recorder.events.append("other-error")
        }
    }

    await parityCancelWhenSleepStarted(sleeper)
    await sleeper.value
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskSleepCancellationProbe()
}
