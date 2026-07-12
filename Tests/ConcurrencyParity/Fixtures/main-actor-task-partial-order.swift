@MainActor
final class Recorder {
    var events: [String] = []
}

@MainActor
func startTasks() -> Recorder {
    let recorder = Recorder()
    Task { recorder.events.append("first") }
    Task { recorder.events.append("second") }
    recorder.events.append("sync")
    return recorder
}

@MainActor
func parityNativeOutput() async throws -> String {
    let recorder = startTasks()
    while recorder.events.count < 3 {
        await Task.yield()
    }
    return recorder.events.joined(separator: ",")
}
