@MainActor
func taskGroupAddDecisionLabel(_ added: Bool) -> String {
    if added {
        return "added"
    }
    return "skipped"
}

@MainActor
func taskGroupAddUnlessCancelledProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        let firstAdded = group.addTaskUnlessCancelled {
            return "first"
        }
        let first = await group.next() ?? "missing-first"

        group.cancelAll()
        let secondAdded = group.addTaskUnlessCancelled {
            return "wrong-second"
        }
        let empty = await group.next() ?? "empty"
        return taskGroupAddDecisionLabel(firstAdded) + ":" + first
            + ":" + taskGroupAddDecisionLabel(secondAdded) + ":" + empty
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupAddUnlessCancelledProbe()
}
