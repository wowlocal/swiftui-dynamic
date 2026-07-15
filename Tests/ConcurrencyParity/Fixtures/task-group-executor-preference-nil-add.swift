@MainActor
final class TaskGroupExecutorPreferenceRecorder {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func waitForCount(_ count: Int) async {
        while values.count < count {
            await Task.yield()
        }
    }

    func output() -> String {
        values.sorted().joined(separator: "|")
    }
}

func taskGroupExecutorPreferenceObservation(_ label: String) -> String {
    label + ":" + (Task.name ?? "nil")
}

@MainActor
func taskGroupExecutorPreferenceNilAddProbe() async throws -> String {
    let recorder = TaskGroupExecutorPreferenceRecorder()

    await withTaskGroup(of: Void.self) { group in
        group.addTask(executorPreference: nil, priority: .high) {
            let value = taskGroupExecutorPreferenceObservation(
                "ordinary-unnamed")
            await recorder.record(value)
        }
        group.addTask(
            name: "ordinary-name",
            executorPreference: nil,
            priority: .high
        ) {
            let value = taskGroupExecutorPreferenceObservation(
                "ordinary-named")
            await recorder.record(value)
        }
        await recorder.waitForCount(2)
    }

    await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask(executorPreference: nil, priority: .high) {
            let value = taskGroupExecutorPreferenceObservation(
                "throwing-unnamed")
            await recorder.record(value)
        }
        group.addTask(
            name: "throwing-name",
            executorPreference: nil,
            priority: .high
        ) {
            let value = taskGroupExecutorPreferenceObservation(
                "throwing-named")
            await recorder.record(value)
        }
        await recorder.waitForCount(4)
    }

    await withDiscardingTaskGroup { group in
        group.addTask(executorPreference: nil, priority: .high) {
            let value = taskGroupExecutorPreferenceObservation(
                "discarding-unnamed")
            await recorder.record(value)
        }
        group.addTask(
            name: "discarding-name",
            executorPreference: nil,
            priority: .high
        ) {
            let value = taskGroupExecutorPreferenceObservation(
                "discarding-named")
            await recorder.record(value)
        }
        await recorder.waitForCount(6)
    }

    try await withThrowingDiscardingTaskGroup { group in
        group.addTask(executorPreference: nil, priority: .high) {
            let value = taskGroupExecutorPreferenceObservation(
                "throwing-discarding-unnamed")
            await recorder.record(value)
        }
        group.addTask(
            name: "throwing-discarding-name",
            executorPreference: nil,
            priority: .high
        ) {
            let value = taskGroupExecutorPreferenceObservation(
                "throwing-discarding-named")
            await recorder.record(value)
        }
        await recorder.waitForCount(8)
    }

    return recorder.output()
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await taskGroupExecutorPreferenceNilAddProbe()
}
