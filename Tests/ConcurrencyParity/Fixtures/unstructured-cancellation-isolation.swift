@MainActor
final class UnstructuredCancellationRecorder {
    var parent: Task<Void, Error>?
    var child: Task<String, Never>?
}

@MainActor
func startUnstructuredCancellationProbe() -> UnstructuredCancellationRecorder {
    let recorder = UnstructuredCancellationRecorder()
    recorder.parent = Task {
        let child = Task {
            await parityWaitTaskValueGate()
            return "child"
        }
        recorder.child = child
        try await parityWaitForever()
    }
    return recorder
}

@MainActor
func unstructuredCancellationIsolationProbe() async -> String {
    let recorder = startUnstructuredCancellationProbe()
    await parityAwaitWaitStarted()
    recorder.parent?.cancel()
    parityOpenTaskValueGate()

    let parentState: String
    if let parent = recorder.parent {
        do {
            try await parent.value
            parentState = "parent-succeeded"
        } catch is CancellationError {
            parentState = "cancelled"
        } catch {
            parentState = "parent-failed"
        }
    } else {
        parentState = "missing-parent"
    }

    guard let child = recorder.child else {
        return parentState + ",missing-child"
    }
    return parentState + "," + (await child.value)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await unstructuredCancellationIsolationProbe()
}
