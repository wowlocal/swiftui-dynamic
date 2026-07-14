@MainActor
var taskGroupOwnerCancellationReady = false

@MainActor
func taskGroupAwaitOwnerCancellationReady() async {
    while !taskGroupOwnerCancellationReady {
        await Task.yield()
    }
}

@MainActor
func taskGroupOwnerCancellationLabel(_ isCancelled: Bool) -> String {
    if isCancelled {
        return "cancelled"
    }
    return "active"
}

@MainActor
func taskGroupOwnerAddDecisionLabel(_ added: Bool) -> String {
    if added {
        return "added"
    }
    return "skipped"
}

@MainActor
func taskGroupOwnerLateChild() async -> String {
    if Task.isCancelled {
        return "child-cancelled"
    }
    return "child-active"
}

@MainActor
func taskGroupOwnerCancellationBody() async -> String {
    await withTaskGroup(of: String.self) { group in
        taskGroupOwnerCancellationReady = true
        while !Task.isCancelled {
            await Task.yield()
        }

        let owner = taskGroupOwnerCancellationLabel(Task.isCancelled)
        let groupState = taskGroupOwnerCancellationLabel(group.isCancelled)
        let conditional = taskGroupOwnerAddDecisionLabel(
            group.addTaskUnlessCancelled {
                return "wrong-conditional"
            })
        group.addTask {
            await taskGroupOwnerLateChild()
        }
        let child = await group.next() ?? "empty"
        return owner + ":" + groupState + ":" + conditional + ":" + child
    }
}

@MainActor
func taskGroupOwnerCancellationProbe() async -> String {
    let owner = Task {
        await taskGroupOwnerCancellationBody()
    }
    await taskGroupAwaitOwnerCancellationReady()
    owner.cancel()
    return await owner.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupOwnerCancellationProbe()
}
