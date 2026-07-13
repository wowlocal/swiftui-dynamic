@MainActor
final class AsyncLetTuplePatternRecorder {
    var events: [String] = []
}

@MainActor
func asyncLetTupleChild(
    _ recorder: AsyncLetTuplePatternRecorder
) async -> (String, String) {
    recorder.events.append("child-start")
    await parityWaitTaskValueGate()
    recorder.events.append("child-end")
    return ("left", "right")
}

@MainActor
func asyncLetTuplePatternProbe() async -> String {
    let recorder = AsyncLetTuplePatternRecorder()
    async let (left, right) = asyncLetTupleChild(recorder)

    await parityAwaitTaskValueGateStarted()
    recorder.events.append("parent-open")
    parityOpenTaskValueGate()

    let first = await left
    let second = await right
    recorder.events.append(first)
    recorder.events.append(second)
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetTuplePatternProbe()
}
