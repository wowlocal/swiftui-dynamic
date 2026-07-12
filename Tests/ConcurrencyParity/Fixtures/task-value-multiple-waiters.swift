@MainActor
final class MultipleTaskWaiterRecorder {
    var events: [String] = []
}

@MainActor
func startMultipleTaskWaiterProbe() -> MultipleTaskWaiterRecorder {
    let recorder = MultipleTaskWaiterRecorder()
    let source = Task {
        await parityWaitTaskValueGate()
        return "value"
    }
    parityRegisterTaskValueSource(source)
    Task {
        parityMarkTaskValueWaiter()
        let value = await source.value
        recorder.events.append("first:" + value)
    }
    Task {
        parityMarkTaskValueWaiter()
        let value = await source.value
        recorder.events.append("second:" + value)
    }
    Task {
        await parityAwaitTaskValueWaiters()
        parityOpenTaskValueGate()
    }
    return recorder
}

@MainActor
func parityNativeOutput() async throws -> String {
    let recorder = startMultipleTaskWaiterProbe()
    while recorder.events.count < 2 {
        await Task.yield()
    }
    return recorder.events.joined(separator: ",")
}
