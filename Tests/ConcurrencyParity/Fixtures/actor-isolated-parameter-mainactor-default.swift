func mainActorDefaultedIsolationObservation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    let presence = isolation == nil ? "nil" : "actor"
    return presence + ":" + parityCurrentExecutorLane()
}

@MainActor
func actorIsolatedParameterMainActorDefaultProbe() -> String {
    let inherited = mainActorDefaultedIsolationObservation()
    let explicitNil = mainActorDefaultedIsolationObservation(
        isolation: nil)
    return inherited + "|" + explicitNil
}

@MainActor
func parityNativeOutput() async throws -> String {
    actorIsolatedParameterMainActorDefaultProbe()
}
