actor PhysicalAsyncActorIntegerSourceCallProbe {
    private var observation = ""
    private var finished = false

    private func handle(terminationStatus: Int) async {
        observation = "start:\(terminationStatus)"
        await Task.yield()
        observation += "|done:\(terminationStatus)"
        finished = true
    }

    func launch(status: Int) {
        Task.detached(priority: .utility) {
            await self.handle(terminationStatus: status)
        }
    }

    func result() async -> String {
        while !finished {
            await Task.yield()
        }
        return observation
    }
}

func parallelDetachedAsyncActorIntegerSourceCallProbe() async -> String {
    let probe = PhysicalAsyncActorIntegerSourceCallProbe()
    await probe.launch(status: 17)
    return await probe.result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedAsyncActorIntegerSourceCallProbe()
}
