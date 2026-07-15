@MainActor
final class TaskGroupCancellationStormRecorder {
    var started = 0
}

@MainActor
func taskGroupCancellationStormChild(
    _ recorder: TaskGroupCancellationStormRecorder
) async -> Int {
    recorder.started += 1
    do {
        try await Task.sleep(for: .seconds(30))
        return 0
    } catch is CancellationError {
        return Task.isCancelled ? 1 : -1_000
    } catch {
        return -10_000
    }
}

@MainActor
func taskGroupCancellationStorm(
    fanout: Int,
    cancelBeforeAdding: Bool,
    cancellationRequestCount: Int
) async -> String {
    let recorder = TaskGroupCancellationStormRecorder()
    let summary = await withTaskGroup(of: Int.self) { group in
        if cancelBeforeAdding {
            for _ in 0..<cancellationRequestCount {
                group.cancelAll()
            }
        }

        for _ in 0..<fanout {
            group.addTask {
                await taskGroupCancellationStormChild(recorder)
            }
        }

        while recorder.started < fanout {
            await Task.yield()
        }

        if !cancelBeforeAdding {
            for _ in 0..<cancellationRequestCount {
                group.cancelAll()
            }
        }

        var completed = 0
        var observedCancellation = 0
        for await value in group {
            completed += 1
            observedCancellation += value
        }
        let state = group.isCancelled ? "cancelled" : "active"
        return "\(completed):\(observedCancellation):" + state
    }
    let owner = Task.isCancelled ? "owner-cancelled" : "owner-active"
    return summary + ":" + owner
}

@MainActor
func taskGroupCancellationStormProbe() async -> String {
    await taskGroupCancellationStorm(
        fanout: 32,
        cancelBeforeAdding: false,
        cancellationRequestCount: 4)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupCancellationStormProbe()
}
