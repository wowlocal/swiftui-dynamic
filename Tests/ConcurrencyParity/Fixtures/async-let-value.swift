@MainActor
final class AsyncLetValueRecorder {
    var events: [String] = []
}

@MainActor
func asyncLetChild(_ recorder: AsyncLetValueRecorder) async -> String {
    recorder.events.append("child-start")
    await parityWaitTaskValueGate()
    recorder.events.append("child-end")
    return "value"
}

@MainActor
func asyncLetValueProbe() async -> String {
    let recorder = AsyncLetValueRecorder()
    async let value = asyncLetChild(recorder)

    await parityAwaitTaskValueGateStarted()
    recorder.events.append("parent-open")
    parityOpenTaskValueGate()

    let result = await value
    recorder.events.append(result)
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetValueProbe()
}
