@MainActor
final class ConcurrentExecutorHopProbe {
    func mainLane() -> String {
        parityCurrentExecutorLane()
    }

    @concurrent
    nonisolated func work() async -> String {
        let entered = parityCurrentExecutorLane()
        await Task.yield()
        let resumed = parityCurrentExecutorLane()
        let hopped = await mainLane()
        return entered + ":" + resumed + ":" + hopped
    }

    func run() async -> String {
        let root = parityCurrentExecutorLane()
        let direct = await work()
        let detached = await Task.detached {
            await self.work()
        }.value
        let returned = parityCurrentExecutorLane()
        return root + "|" + direct + "|" + detached + "|" + returned
    }
}

@MainActor
func concurrentExecutorHopProbe() async -> String {
    await ConcurrentExecutorHopProbe().run()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await concurrentExecutorHopProbe()
}
