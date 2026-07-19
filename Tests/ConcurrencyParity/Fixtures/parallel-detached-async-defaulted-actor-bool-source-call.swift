actor PhysicalAsyncDefaultedActorBooleanSourceCallProbe {
    private var observation = ""
    private var finished = false

    private func setup(andLaunch launch: Bool = false) async {
        observation = "start:\(launch)"
        await Task.yield()
        observation += "|done:\(launch)"
        finished = true
    }

    func launch() {
        Task.detached(priority: .utility) {
            await self.setup(andLaunch: true)
        }
    }

    func result() async -> String {
        while !finished {
            await Task.yield()
        }
        return observation
    }
}

func parallelDetachedAsyncDefaultedActorBooleanSourceCallProbe() async
    -> String
{
    let probe = PhysicalAsyncDefaultedActorBooleanSourceCallProbe()
    await probe.launch()
    return await probe.result()
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedAsyncDefaultedActorBooleanSourceCallProbe()
}
