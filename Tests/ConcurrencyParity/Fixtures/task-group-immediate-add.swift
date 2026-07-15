@MainActor
final class TaskGroupImmediateRecorder {
    private var events: [String] = []
    private var released: Set<String> = []

    func record(_ event: String) {
        events.append(event)
    }

    func waitUntilReleased(_ gate: String) async {
        while !released.contains(gate) {
            await Task.yield()
        }
    }

    func release(_ gate: String) {
        released.insert(gate)
    }

    func output() -> String {
        events.joined(separator: ",")
    }
}

func taskGroupImmediateStart(_ gate: String) -> String {
    "\(gate)-start:\(Task.name ?? "nil")"
}

@MainActor
func taskGroupImmediateAddProbe() async throws -> String {
    let recorder = TaskGroupImmediateRecorder()

    await withTaskGroup(of: Void.self) { group in
        let addGate = "ordinary-add"
        group.addImmediateTask(
            name: addGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(addGate))
            await recorder.waitUntilReleased(addGate)
            recorder.record("\(addGate)-finish")
        }
        recorder.record("\(addGate)-after")
        recorder.release(addGate)

        let unlessGate = "ordinary-unless"
        let accepted = group.addImmediateTaskUnlessCancelled(
            name: unlessGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(unlessGate))
            await recorder.waitUntilReleased(unlessGate)
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-after:\(accepted)")
        recorder.release(unlessGate)
        group.cancelAll()
        let rejected = group.addImmediateTaskUnlessCancelled(
            name: "ordinary-rejected",
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-rejected:\(rejected)")
    }

    await withThrowingTaskGroup(of: Void.self) { group in
        let addGate = "throwing-add"
        group.addImmediateTask(
            name: addGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(addGate))
            await recorder.waitUntilReleased(addGate)
            recorder.record("\(addGate)-finish")
        }
        recorder.record("\(addGate)-after")
        recorder.release(addGate)

        let unlessGate = "throwing-unless"
        let accepted = group.addImmediateTaskUnlessCancelled(
            name: unlessGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(unlessGate))
            await recorder.waitUntilReleased(unlessGate)
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-after:\(accepted)")
        recorder.release(unlessGate)
        group.cancelAll()
        let rejected = group.addImmediateTaskUnlessCancelled(
            name: "throwing-rejected",
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-rejected:\(rejected)")
    }

    await withDiscardingTaskGroup { group in
        let addGate = "discarding-add"
        group.addImmediateTask(
            name: addGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(addGate))
            await recorder.waitUntilReleased(addGate)
            recorder.record("\(addGate)-finish")
        }
        recorder.record("\(addGate)-after")
        recorder.release(addGate)

        let unlessGate = "discarding-unless"
        let accepted = group.addImmediateTaskUnlessCancelled(
            name: unlessGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(unlessGate))
            await recorder.waitUntilReleased(unlessGate)
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-after:\(accepted)")
        recorder.release(unlessGate)
        group.cancelAll()
        let rejected = group.addImmediateTaskUnlessCancelled(
            name: "discarding-rejected",
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-rejected:\(rejected)")
    }

    try await withThrowingDiscardingTaskGroup { group in
        let addGate = "throwing-discarding-add"
        group.addImmediateTask(
            name: addGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(addGate))
            await recorder.waitUntilReleased(addGate)
            recorder.record("\(addGate)-finish")
        }
        recorder.record("\(addGate)-after")
        recorder.release(addGate)

        let unlessGate = "throwing-discarding-unless"
        let accepted = group.addImmediateTaskUnlessCancelled(
            name: unlessGate,
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record(taskGroupImmediateStart(unlessGate))
            await recorder.waitUntilReleased(unlessGate)
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-after:\(accepted)")
        recorder.release(unlessGate)
        group.cancelAll()
        let rejected = group.addImmediateTaskUnlessCancelled(
            name: "throwing-discarding-rejected",
            priority: nil,
            executorPreference: nil
        ) {
            recorder.record("\(unlessGate)-finish")
        }
        recorder.record("\(unlessGate)-rejected:\(rejected)")
    }

    return recorder.output()
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await taskGroupImmediateAddProbe()
}
