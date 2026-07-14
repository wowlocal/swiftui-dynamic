@MainActor
func taskGroupWaitForAllRemainingChild() async -> String {
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
func taskGroupWaitForAllConsumesResultsProbe() async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask {
            await taskGroupWaitForAllRemainingChild()
        }
        await parityAwaitWaitStarted()
        group.addTask {
            return "fast"
        }

        let first = await group.next() ?? "missing-first"
        group.cancelAll()
        await group.waitForAll()
        let empty = await group.next() ?? "empty"
        return first + ":" + empty
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupWaitForAllConsumesResultsProbe()
}
