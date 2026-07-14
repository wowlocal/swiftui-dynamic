@MainActor
final class HostCallbackTaskRuntimeProbe {
    var phase = "idle"
    var worker: Task<Void, Never>?

    func makeCallback() -> () -> Void {
        {
            self.phase = "started"
            self.worker = Task.detached {
                let total = await withTaskGroup(of: Int.self) { group in
                    group.addTask { 1 }
                    group.addTask { 2 }
                    let first = await group.next() ?? 0
                    let second = await group.next() ?? 0
                    return first + second
                }
                await self.finish(total)
            }
        }
    }

    func finish(_ total: Int) {
        phase = "done-\(total)"
    }
}

@MainActor
let parityHostCallbackProbe = HostCallbackTaskRuntimeProbe()

@MainActor
func parityInterpreterHostCallback() -> () -> Void {
    parityHostCallbackProbe.makeCallback()
}

@MainActor
func parityNativeOutput() async throws -> String {
    let callback = parityInterpreterHostCallback()
    callback()
    let immediate = parityHostCallbackProbe.phase
    await parityHostCallbackProbe.worker?.value
    return "\(immediate),\(parityHostCallbackProbe.phase)"
}
