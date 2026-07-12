@MainActor
final class UnstructuredLifetimeRecorder {
    var events: [String] = []
}

@MainActor
func startUnstructuredLifetimeProbe() -> UnstructuredLifetimeRecorder {
    let recorder = UnstructuredLifetimeRecorder()
    Task {
        await parityWaitTaskValueGate()
        recorder.events.append("task")
    }
    recorder.events.append("returned")
    Task {
        await parityAwaitTaskValueGateStarted()
        parityOpenTaskValueGate()
    }
    return recorder
}

@MainActor
func parityNativeOutput() async throws -> String {
    let recorder = startUnstructuredLifetimeProbe()
    while recorder.events.count < 2 {
        await Task.yield()
    }
    return recorder.events.joined(separator: ",")
}
