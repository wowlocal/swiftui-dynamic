@MainActor
func hostBridgedAsyncSequenceProbe() async -> String {
    var count = 0
    var total = 0
    for await value in parityHostAsyncSequence() {
        count += 1
        total += value
    }
    return "\(count):\(total)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await hostBridgedAsyncSequenceProbe()
}
