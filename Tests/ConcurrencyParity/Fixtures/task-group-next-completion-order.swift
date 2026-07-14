@MainActor
func taskGroupNextSlowChild() async -> String {
    do {
        try await parityWaitForever()
        return "wrong-finish"
    } catch is CancellationError {
        return "slow"
    } catch {
        return "wrong-error"
    }
}

@MainActor
func taskGroupNextCompletionOrderProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask {
            await taskGroupNextSlowChild()
        }
        await parityAwaitWaitStarted()
        group.addTask {
            return "fast"
        }

        let first = await group.next() ?? "missing-first"
        group.cancelAll()
        let second = await group.next() ?? "missing-second"
        let empty = await group.next() ?? "empty"
        return first + ":" + second + ":" + empty
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupNextCompletionOrderProbe()
}
