@MainActor
final class TaskGroupExplicitIsolationGate {
    var started = false
    var open = false
}

@MainActor
func waitForTaskGroupExplicitIsolationGate(
    _ gate: TaskGroupExplicitIsolationGate
) async {
    gate.started = true
    while !gate.open {
        await Task.yield()
    }
}

@MainActor
func openTaskGroupExplicitIsolationGate(
    _ gate: TaskGroupExplicitIsolationGate
) async {
    while !gate.started {
        await Task.yield()
    }
    gate.open = true
}

@MainActor
func ordinaryWaitForAllExplicitIsolationProbe() async -> String {
    let gate = TaskGroupExplicitIsolationGate()
    let entered = parityCurrentExecutorLane()
    await withTaskGroup(of: Int.self) { group in
        group.addTask {
            await waitForTaskGroupExplicitIsolationGate(gate)
            return 1
        }
        let opener = Task {
            await openTaskGroupExplicitIsolationGate(gate)
        }
        await group.waitForAll(isolation: MainActor.shared)
        _ = await opener.value
    }
    let resumed = parityCurrentExecutorLane()
    return "ordinary-supported:" + entered + ":" + resumed
}

@MainActor
func throwingWaitForAllExplicitIsolationProbe() async -> String {
    let gate = TaskGroupExplicitIsolationGate()
    let entered = parityCurrentExecutorLane()
    do {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                await waitForTaskGroupExplicitIsolationGate(gate)
                return 2
            }
            let opener = Task {
                await openTaskGroupExplicitIsolationGate(gate)
            }
            try await group.waitForAll(isolation: MainActor.shared)
            _ = await opener.value
        }
        let resumed = parityCurrentExecutorLane()
        return "throwing-supported:" + entered + ":" + resumed
    } catch {
        return "throwing-unsupported"
    }
}

@MainActor
func taskGroupWaitForAllExplicitIsolationProbe() async -> String {
    let ordinary = await ordinaryWaitForAllExplicitIsolationProbe()
    let throwing = await throwingWaitForAllExplicitIsolationProbe()
    return ordinary + "|" + throwing
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupWaitForAllExplicitIsolationProbe()
}
