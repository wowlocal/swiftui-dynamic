@MainActor
final class TaskGroupConditionalExecutorPreferenceRecorder {
    private var childValues: [String] = []
    private var decisions: [String] = []

    func recordChild(_ value: String) {
        childValues.append(value)
    }

    func recordDecision(_ value: String) {
        decisions.append(value)
    }

    func waitForChildCount(_ count: Int) async {
        while childValues.count < count {
            await Task.yield()
        }
    }

    func output() -> String {
        (childValues + decisions).sorted().joined(separator: "|")
    }
}

func taskGroupConditionalExecutorPreferenceObservation(
    _ label: String
) -> String {
    label + ":" + (Task.name ?? "nil")
}

@MainActor
func taskGroupExecutorPreferenceNilAddUnlessCancelledProbe()
        async throws -> String {
    let recorder = TaskGroupConditionalExecutorPreferenceRecorder()

    await withTaskGroup(of: Void.self) { group in
        let unnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "ordinary-unnamed")
            await recorder.recordChild(value)
        }
        let named = group.addTaskUnlessCancelled(
            name: "ordinary-name",
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "ordinary-named")
            await recorder.recordChild(value)
        }
        await recorder.waitForChildCount(2)
        group.cancelAll()
        let rejectedUnnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            await recorder.recordChild("ordinary-unexpected")
        }
        let rejectedNamed = group.addTaskUnlessCancelled(
            name: "ordinary-rejected",
            executorPreference: nil
        ) {
            await recorder.recordChild("ordinary-named-unexpected")
        }
        recorder.recordDecision(
            "ordinary-decisions:\(unnamed):\(named):"
                + "\(rejectedUnnamed):\(rejectedNamed)")
    }

    await withThrowingTaskGroup(of: Void.self) { group in
        let unnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "throwing-unnamed")
            await recorder.recordChild(value)
        }
        let named = group.addTaskUnlessCancelled(
            name: "throwing-name",
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "throwing-named")
            await recorder.recordChild(value)
        }
        await recorder.waitForChildCount(4)
        group.cancelAll()
        let rejectedUnnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            await recorder.recordChild("throwing-unexpected")
        }
        let rejectedNamed = group.addTaskUnlessCancelled(
            name: "throwing-rejected",
            executorPreference: nil
        ) {
            await recorder.recordChild("throwing-named-unexpected")
        }
        recorder.recordDecision(
            "throwing-decisions:\(unnamed):\(named):"
                + "\(rejectedUnnamed):\(rejectedNamed)")
    }

    await withDiscardingTaskGroup { group in
        let unnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "discarding-unnamed")
            await recorder.recordChild(value)
        }
        let named = group.addTaskUnlessCancelled(
            name: "discarding-name",
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "discarding-named")
            await recorder.recordChild(value)
        }
        await recorder.waitForChildCount(6)
        group.cancelAll()
        let rejectedUnnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            await recorder.recordChild("discarding-unexpected")
        }
        let rejectedNamed = group.addTaskUnlessCancelled(
            name: "discarding-rejected",
            executorPreference: nil
        ) {
            await recorder.recordChild("discarding-named-unexpected")
        }
        recorder.recordDecision(
            "discarding-decisions:\(unnamed):\(named):"
                + "\(rejectedUnnamed):\(rejectedNamed)")
    }

    try await withThrowingDiscardingTaskGroup { group in
        let unnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "throwing-discarding-unnamed")
            await recorder.recordChild(value)
        }
        let named = group.addTaskUnlessCancelled(
            name: "throwing-discarding-name",
            executorPreference: nil
        ) {
            let value = taskGroupConditionalExecutorPreferenceObservation(
                "throwing-discarding-named")
            await recorder.recordChild(value)
        }
        await recorder.waitForChildCount(8)
        group.cancelAll()
        let rejectedUnnamed = group.addTaskUnlessCancelled(
            executorPreference: nil
        ) {
            await recorder.recordChild("throwing-discarding-unexpected")
        }
        let rejectedNamed = group.addTaskUnlessCancelled(
            name: "throwing-discarding-rejected",
            executorPreference: nil
        ) {
            await recorder.recordChild(
                "throwing-discarding-named-unexpected")
        }
        recorder.recordDecision(
            "throwing-discarding-decisions:\(unnamed):\(named):"
                + "\(rejectedUnnamed):\(rejectedNamed)")
    }

    return recorder.output()
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await taskGroupExecutorPreferenceNilAddUnlessCancelledProbe()
}
