@MainActor
final class TaskGroupNameRecorder {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func output() -> String {
        values.sorted().joined(separator: "|")
    }
}

@MainActor
func taskGroupNamedAddProbe() async throws -> String {
    let recorder = TaskGroupNameRecorder()

    await withTaskGroup(of: Void.self) { group in
        group.addTask(name: "ordinary-add") {
            await recorder.record(Task.name ?? "nil")
        }
        let accepted = group.addTaskUnlessCancelled(name: "ordinary-unless") {
            await recorder.record(Task.name ?? "nil")
        }
        if !accepted {
            recorder.record("ordinary-unless-rejected")
        }
    }

    await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask(name: "throwing-add") {
            await recorder.record(Task.name ?? "nil")
        }
        let accepted = group.addTaskUnlessCancelled(name: "throwing-unless") {
            await recorder.record(Task.name ?? "nil")
        }
        if !accepted {
            recorder.record("throwing-unless-rejected")
        }
    }

    await withDiscardingTaskGroup { group in
        group.addTask(name: "discarding-add") {
            await recorder.record(Task.name ?? "nil")
        }
        let accepted = group.addTaskUnlessCancelled(name: "discarding-unless") {
            await recorder.record(Task.name ?? "nil")
        }
        if !accepted {
            recorder.record("discarding-unless-rejected")
        }
    }

    try await withThrowingDiscardingTaskGroup { group in
        group.addTask(name: "throwing-discarding-add") {
            await recorder.record(Task.name ?? "nil")
        }
        let accepted = group.addTaskUnlessCancelled(
            name: "throwing-discarding-unless"
        ) {
            await recorder.record(Task.name ?? "nil")
        }
        if !accepted {
            recorder.record("throwing-discarding-unless-rejected")
        }
    }

    return recorder.output()
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await taskGroupNamedAddProbe()
}
