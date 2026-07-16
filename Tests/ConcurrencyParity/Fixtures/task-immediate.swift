enum TaskImmediateLocal {
    @TaskLocal static var value = "default"
}

enum TaskImmediateFailure: Error {
    case ordinary
    case detached
}

@MainActor
final class TaskImmediateRecorder {
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

@MainActor
func taskImmediateProbe() async -> String {
    let recorder = TaskImmediateRecorder()

    return await TaskImmediateLocal.$value.withValue("parent") {
        let ordinaryGate = "ordinary"
        let ordinary = Task.immediate(
            name: ordinaryGate,
            priority: .low,
            executorPreference: nil
        ) {
            recorder.record(
                "ordinary-start:\(Task.name ?? "nil")"
                    + ":\(TaskImmediateLocal.value)"
                    + ":\(Int(Task.currentPriority.rawValue))")
            await recorder.waitUntilReleased(ordinaryGate)
            recorder.record("ordinary-finish")
            return 11
        }
        recorder.record("ordinary-after")
        recorder.release(ordinaryGate)

        let detachedGate = "detached"
        let detached = Task.immediateDetached(
            name: detachedGate,
            priority: .background,
            executorPreference: nil
        ) {
            recorder.record(
                "detached-start:\(Task.name ?? "nil")"
                    + ":\(TaskImmediateLocal.value)"
                    + ":\(Int(Task.currentPriority.rawValue))")
            await recorder.waitUntilReleased(detachedGate)
            recorder.record("detached-finish")
            return 33
        }
        recorder.record("detached-after")
        recorder.release(detachedGate)

        let throwingGate = "ordinary-throwing"
        let throwing = Task.immediate(
            name: throwingGate,
            priority: .high,
            executorPreference: nil
        ) {
            recorder.record(
                "ordinary-throwing-start:\(Task.name ?? "nil")"
                    + ":\(TaskImmediateLocal.value)"
                    + ":\(Int(Task.currentPriority.rawValue))")
            await recorder.waitUntilReleased(throwingGate)
            recorder.record("ordinary-throwing-finish")
            throw TaskImmediateFailure.ordinary
        }
        recorder.record("ordinary-throwing-after")
        recorder.release(throwingGate)

        let detachedThrowingGate = "detached-throwing"
        let detachedThrowing = Task.immediateDetached(
            name: detachedThrowingGate,
            priority: .medium,
            executorPreference: nil
        ) {
            recorder.record(
                "detached-throwing-start:\(Task.name ?? "nil")"
                    + ":\(TaskImmediateLocal.value)"
                    + ":\(Int(Task.currentPriority.rawValue))")
            await recorder.waitUntilReleased(detachedThrowingGate)
            recorder.record("detached-throwing-finish")
            throw TaskImmediateFailure.detached
        }
        recorder.record("detached-throwing-after")
        recorder.release(detachedThrowingGate)

        let ordinaryValue = await ordinary.value
        let detachedValue = await detached.value
        recorder.record("values:\(ordinaryValue):\(detachedValue)")
        do {
            _ = try await throwing.value
            recorder.record("ordinary-throwing-wrong")
        } catch TaskImmediateFailure.ordinary {
            recorder.record("ordinary-throwing-error")
        } catch {
            recorder.record("ordinary-throwing-wrong-error")
        }
        do {
            _ = try await detachedThrowing.value
            recorder.record("detached-throwing-wrong")
        } catch TaskImmediateFailure.detached {
            recorder.record("detached-throwing-error")
        } catch {
            recorder.record("detached-throwing-wrong-error")
        }
        return recorder.output()
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskImmediateProbe()
}
