@MainActor
var taskGroupPreCancelledOwnerReady = false

@MainActor
func taskGroupAwaitPreCancelledOwnerReady() async {
    while !taskGroupPreCancelledOwnerReady {
        await Task.yield()
    }
}

@MainActor
func taskGroupPreCancelledLabel(_ isCancelled: Bool) -> String {
    if isCancelled {
        return "cancelled"
    }
    return "active"
}

@MainActor
func taskGroupPreCancelledAddLabel(_ added: Bool) -> String {
    if added {
        return "added"
    }
    return "skipped"
}

@MainActor
func taskGroupPreCancelledLateChild() async -> String {
    if Task.isCancelled {
        return "child-cancelled"
    }
    return "child-active"
}

@MainActor
func taskGroupPreCancelledOwnerBody() async -> String {
    taskGroupPreCancelledOwnerReady = true
    while !Task.isCancelled {
        await Task.yield()
    }

    return await withTaskGroup(of: String.self) { group in
        let groupState = taskGroupPreCancelledLabel(group.isCancelled)
        let conditional = taskGroupPreCancelledAddLabel(
            group.addTaskUnlessCancelled {
                return "wrong-conditional"
            })
        group.addTask {
            await taskGroupPreCancelledLateChild()
        }
        let child = await group.next() ?? "empty"
        return groupState + ":" + conditional + ":" + child
    }
}

@MainActor
func taskGroupCreatedAfterOwnerCancellationProbe() async -> String {
    let owner = Task {
        await taskGroupPreCancelledOwnerBody()
    }
    await taskGroupAwaitPreCancelledOwnerReady()
    owner.cancel()
    return await owner.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupCreatedAfterOwnerCancellationProbe()
}
