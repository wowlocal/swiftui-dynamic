enum ParityActorTaskLocal {
    @TaskLocal static var value = "default"
}

actor ParityActorTaskLocalActor {
    func read() -> String {
        ParityActorTaskLocal.value
            + ":" + parityActorSegmentOwnership(self)
    }

    func readAcrossSuspension() async -> String {
        let before = read()
        await Task.yield()
        return before + ">" + read()
    }
}

@MainActor
func actorTaskLocalPropagationProbe() async -> String {
    let actor = ParityActorTaskLocalActor()
    let before = await actor.read()
    let bound = await ParityActorTaskLocal.$value.withValue("bound") {
        let immediate = await actor.read()
        let resumed = await actor.readAcrossSuspension()
        return immediate + "|" + resumed
    }
    let after = await actor.read()
    return before + "|" + bound + "|" + after
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorTaskLocalPropagationProbe()
}
