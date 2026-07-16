@MainActor
var parityIsolatedDeinitializerState = "before"

@MainActor
final class ParityIsolatedDeinitializerOwner {
    isolated deinit {
        parityIsolatedDeinitializerState = "deinit"
    }
}

@MainActor
func actorIsolatedDeinitializerProbe() -> String {
    parityIsolatedDeinitializerState = "before"
    do {
        _ = ParityIsolatedDeinitializerOwner()
    }
    return parityIsolatedDeinitializerState
}

@MainActor
func parityNativeOutput() async throws -> String {
    actorIsolatedDeinitializerProbe()
}
