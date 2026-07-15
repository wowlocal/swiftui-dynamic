@MainActor
func taskGroupStateSummary(
    beforeEmpty: Bool,
    beforeCancelled: Bool,
    pendingEmpty: Bool,
    pendingCancelled: Bool,
    afterCancelled: Bool,
    afterEmpty: Bool
) -> String {
    "\(beforeEmpty):\(beforeCancelled):\(pendingEmpty):"
        + "\(pendingCancelled):\(afterCancelled):\(afterEmpty)"
}

@MainActor
func ordinaryTaskGroupStateProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        let beforeEmpty = group.isEmpty
        let beforeCancelled = group.isCancelled
        group.addTask {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return "done"
        }
        let pendingEmpty = group.isEmpty
        let pendingCancelled = group.isCancelled
        group.cancelAll()
        let afterCancelled = group.isCancelled
        _ = await group.next()
        return taskGroupStateSummary(
            beforeEmpty: beforeEmpty,
            beforeCancelled: beforeCancelled,
            pendingEmpty: pendingEmpty,
            pendingCancelled: pendingCancelled,
            afterCancelled: afterCancelled,
            afterEmpty: group.isEmpty)
    }
}

@MainActor
func throwingTaskGroupStateProbe() async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        let beforeEmpty = group.isEmpty
        let beforeCancelled = group.isCancelled
        group.addTask {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return "done"
        }
        let pendingEmpty = group.isEmpty
        let pendingCancelled = group.isCancelled
        group.cancelAll()
        let afterCancelled = group.isCancelled
        _ = try await group.next()
        return taskGroupStateSummary(
            beforeEmpty: beforeEmpty,
            beforeCancelled: beforeCancelled,
            pendingEmpty: pendingEmpty,
            pendingCancelled: pendingCancelled,
            afterCancelled: afterCancelled,
            afterEmpty: group.isEmpty)
    }
}

@MainActor
func discardingTaskGroupStateProbe() async -> String {
    await withDiscardingTaskGroup(returning: String.self) { group in
        let beforeEmpty = group.isEmpty
        let beforeCancelled = group.isCancelled
        group.addTask {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let pendingEmpty = group.isEmpty
        let pendingCancelled = group.isCancelled
        group.cancelAll()
        let afterCancelled = group.isCancelled
        while !group.isEmpty {
            await Task.yield()
        }
        return taskGroupStateSummary(
            beforeEmpty: beforeEmpty,
            beforeCancelled: beforeCancelled,
            pendingEmpty: pendingEmpty,
            pendingCancelled: pendingCancelled,
            afterCancelled: afterCancelled,
            afterEmpty: group.isEmpty)
    }
}

@MainActor
func throwingDiscardingTaskGroupStateProbe() async throws -> String {
    try await withThrowingDiscardingTaskGroup(
        returning: String.self
    ) { group in
        let beforeEmpty = group.isEmpty
        let beforeCancelled = group.isCancelled
        group.addTask {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let pendingEmpty = group.isEmpty
        let pendingCancelled = group.isCancelled
        group.cancelAll()
        let afterCancelled = group.isCancelled
        while !group.isEmpty {
            await Task.yield()
        }
        return taskGroupStateSummary(
            beforeEmpty: beforeEmpty,
            beforeCancelled: beforeCancelled,
            pendingEmpty: pendingEmpty,
            pendingCancelled: pendingCancelled,
            afterCancelled: afterCancelled,
            afterEmpty: group.isEmpty)
    }
}

@MainActor
func taskGroupStatePropertiesProbe() async throws -> String {
    let ordinary = await ordinaryTaskGroupStateProbe()
    let throwing = try await throwingTaskGroupStateProbe()
    let discarding = await discardingTaskGroupStateProbe()
    let throwingDiscarding = try await throwingDiscardingTaskGroupStateProbe()
    return "ordinary=" + ordinary
        + "|throwing=" + throwing
        + "|discarding=" + discarding
        + "|throwing-discarding=" + throwingDiscarding
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await taskGroupStatePropertiesProbe()
}
