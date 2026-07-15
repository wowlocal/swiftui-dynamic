@MainActor
func taskExecutorCompositionProbe() async -> String {
    let root = parityCurrentExecutorLane()
    let task = Task {
        let taskLane = parityCurrentExecutorLane()
        async let asyncLetLane = parityCurrentExecutorLane()
        let groupLanes = await withTaskGroup(of: String.self) { group in
            group.addTask {
                let groupLane = parityCurrentExecutorLane()
                let nestedTaskLane = await Task {
                    parityCurrentExecutorLane()
                }.value
                return groupLane + ":" + nestedTaskLane
            }
            return await group.next()!
        }
        return taskLane + ":" + (await asyncLetLane) + ":" + groupLanes
    }
    return root + "|" + (await task.value)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskExecutorCompositionProbe()
}
