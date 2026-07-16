actor ParityComputedSetterCounter {
    var stored = 0
    var setterOwnership = "unset"

    var value: Int {
        get { stored }
        set {
            setterOwnership = parityActorSegmentOwnership(self)
            stored = newValue
        }
    }

    func assign(_ newValue: Int) -> String {
        value = newValue
        return setterOwnership + ":" + String(stored)
    }
}

@MainActor
func actorComputedSetterProbe() async -> String {
    let counter = ParityComputedSetterCounter()
    let first = await counter.assign(7)
    let second = await counter.assign(11)
    return first + "|" + second
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorComputedSetterProbe()
}
