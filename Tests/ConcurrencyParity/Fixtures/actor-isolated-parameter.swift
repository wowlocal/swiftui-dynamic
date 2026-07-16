actor ParityIsolatedParameterCounter {
    var stored = 0

    func current() -> Int {
        stored
    }
}

func addToIsolatedCounter(
    _ counter: isolated ParityIsolatedParameterCounter,
    by amount: Int
) -> String {
    let ownership = parityActorSegmentOwnership(counter)
    guard ownership == "owned" else { return ownership }
    counter.stored += amount
    return ownership + ":" + String(counter.stored)
}

@MainActor
func actorIsolatedParameterProbe() async -> String {
    let counter = ParityIsolatedParameterCounter()
    let first = await addToIsolatedCounter(counter, by: 2)
    let second = await addToIsolatedCounter(counter, by: 3)
    let final = await counter.current()
    return first + "|" + second + "|" + String(final)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await actorIsolatedParameterProbe()
}
