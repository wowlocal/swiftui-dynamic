actor ParitySubscriptSetterCounter {
    var stored = 0
    var setterOwnership = "unset"

    subscript(_ index: Int) -> Int {
        get { stored + index }
        set {
            setterOwnership = parityActorSegmentOwnership(self)
            stored = newValue
        }
    }

    func assign(_ newValue: Int) -> String {
        self[0] = newValue
        return setterOwnership + ":" + String(stored)
    }
}

@MainActor
func actorSubscriptSetterProbe() async -> String {
    let counter = ParitySubscriptSetterCounter()
    let first = await counter.assign(7)
    let second = await counter.assign(11)
    return first + "|" + second
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorSubscriptSetterProbe()
}
