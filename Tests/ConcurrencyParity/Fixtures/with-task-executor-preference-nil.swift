import Foundation

enum TaskExecutorPreferenceProbeError: Error {
    case expected
}

enum TaskExecutorPreferenceProbeLocal {
    @TaskLocal static var value = "default"
}

nonisolated func taskExecutorPreferenceSuccessOperation() async -> String {
    await withUnsafeCurrentTask { task in
        guard let task else { return "false:nil:false:missing:false" }
        await Task.yield()
        let sameTask = withUnsafeCurrentTask { current in
            guard let current else { return false }
            return current == task
        }
        return "\(sameTask)"
            + ":\(Task.name ?? "nil")"
            + ":\(Int(Task.currentPriority.rawValue))"
            + ":\(TaskExecutorPreferenceProbeLocal.value)"
            + ":\(Task.isCancelled)"
    }
}

nonisolated func taskExecutorPreferenceFailureOperation() async
    throws(TaskExecutorPreferenceProbeError) -> String {
    await Task.yield()
    throw TaskExecutorPreferenceProbeError.expected
}

nonisolated func taskExecutorPreferenceCancellationOperation() async -> String {
    let before = Task.isCancelled
    withUnsafeCurrentTask { $0?.cancel() }
    await Task.yield()
    return "\(before):\(Task.isCancelled):\(Task.name ?? "nil")"
}

nonisolated func taskExecutorPreferenceNilProbe() async -> String {
    let success = Task.detached(
        name: "preference-success",
        priority: .high
    ) {
        await TaskExecutorPreferenceProbeLocal.$value.withValue("bound") {
            await withUnsafeCurrentTask { task in
                guard let task else { return "success:nil" }
                let scoped = await withTaskExecutorPreference(
                    nil,
                    isolation: nil,
                    operation: taskExecutorPreferenceSuccessOperation)
                let sameTask = withUnsafeCurrentTask { current in
                    guard let current else { return false }
                    return current == task
                }
                return "success:\(scoped)"
                    + ":\(sameTask)"
                    + ":\(Task.name ?? "nil")"
                    + ":\(Int(Task.currentPriority.rawValue))"
                    + ":\(TaskExecutorPreferenceProbeLocal.value)"
                    + ":\(Task.isCancelled)"
            }
        }
    }

    let failure = Task.detached {
        do {
            let _: String = try await withTaskExecutorPreference(
                nil,
                isolation: nil,
                operation: taskExecutorPreferenceFailureOperation)
            return "error:false"
        } catch TaskExecutorPreferenceProbeError.expected {
            return "error:true"
        } catch {
            return "error:wrong"
        }
    }

    let cancellation = Task.detached(
        name: "preference-cancel",
        priority: .high
    ) {
        let before = Task.isCancelled
        let inside = await withTaskExecutorPreference(
            nil,
            isolation: nil,
            operation: taskExecutorPreferenceCancellationOperation)
        return "cancel:\(before):\(inside):\(Task.isCancelled)"
    }

    return (await success.value)
        + "|" + (await failure.value)
        + "|" + (await cancellation.value)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskExecutorPreferenceNilProbe()
}
