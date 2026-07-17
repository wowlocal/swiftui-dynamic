@MainActor
final class HostCallbackOverlapProbe {
    var events: [String] = []
    var continuation: CheckedContinuation<Void, Never>?
    var worker: Task<Void, Never>?
    var invocation = 0

    func makeCallback() -> () -> Void {
        {
            self.invocation += 1
            if self.invocation == 1 {
                self.events.append("first-inline")
                self.worker = Task {
                    self.events.append("worker-started")
                    await withCheckedContinuation { continuation in
                        self.continuation = continuation
                    }
                    self.events.append("worker-resumed")
                }
                return
            }

            self.events.append("second-inline")
            self.continuation?.resume()
            self.events.append("second-return")
        }
    }

    func output() -> String {
        events.joined(separator: ",")
    }
}

@MainActor
let parityHostCallbackOverlapProbe = HostCallbackOverlapProbe()

@MainActor
func parityInterpreterHostCallbackOverlap() -> () -> Void {
    parityHostCallbackOverlapProbe.makeCallback()
}

@MainActor
func parityNativeOutput() async throws -> String {
    let callback = parityInterpreterHostCallbackOverlap()
    callback()
    while parityHostCallbackOverlapProbe.continuation == nil {
        await Task.yield()
    }
    let parked = parityHostCallbackOverlapProbe.output()
    callback()
    let immediate = parityHostCallbackOverlapProbe.output()
    await parityHostCallbackOverlapProbe.worker?.value
    return "\(parked)|\(immediate)|\(parityHostCallbackOverlapProbe.output())"
}
