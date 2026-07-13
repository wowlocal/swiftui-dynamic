@MainActor
final class AsyncLetMultipleBindingsRecorder {
    var events: [String] = []
    var started = 0
}

@MainActor
func multipleBindingChild(
    _ name: String,
    value: String,
    recorder: AsyncLetMultipleBindingsRecorder
) async -> String {
    recorder.events.append(name + "-start")
    recorder.started += 1
    await parityWaitTaskValueGate()
    recorder.events.append(name + "-end")
    return value
}

@MainActor
func asyncLetMultipleBindingsProbe() async -> String {
    let recorder = AsyncLetMultipleBindingsRecorder()
    async let first = multipleBindingChild(
        "first", value: "one", recorder: recorder),
        second = multipleBindingChild(
            "second", value: "two", recorder: recorder)

    while recorder.started < 2 {
        await Task.yield()
    }
    recorder.events.append("parent-open")
    parityOpenTaskValueGate()

    let firstValue = await first
    recorder.events.append("first-value:" + firstValue)
    let secondValue = await second
    recorder.events.append("second-value:" + secondValue)
    return recorder.events.joined(separator: ",")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetMultipleBindingsProbe()
}
