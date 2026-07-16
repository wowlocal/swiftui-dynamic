@globalActor
actor ParityTeardownActor {
    static let shared = ParityTeardownActor()
}

@ParityTeardownActor
var parityGlobalActorDeinitializerState = "before"

final class ParityGlobalActorDeinitializerOwner {
    @ParityTeardownActor
    deinit {
        parityGlobalActorDeinitializerState = "deinit"
    }
}

@ParityTeardownActor
func actorGlobalActorDeinitializerProbe() -> String {
    parityGlobalActorDeinitializerState = "before"
    do {
        _ = ParityGlobalActorDeinitializerOwner()
    }
    return parityGlobalActorDeinitializerState
}

func parityNativeOutput() async throws -> String {
    await actorGlobalActorDeinitializerProbe()
}
