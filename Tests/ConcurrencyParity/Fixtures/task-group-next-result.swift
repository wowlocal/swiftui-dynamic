enum TaskGroupNextResultProbeError: Error {
    case child
}

@MainActor
func taskGroupNextResultProbe() async -> String {
    var observations: [String] = []
    let entered = parityCurrentExecutorLane()

    await withThrowingTaskGroup(of: String.self) { group in
        switch await group.nextResult(isolation: MainActor.shared) {
        case .none:
            observations.append("empty")
        case .success, .failure:
            observations.append("nonempty")
        }

        group.addTask {
            "value"
        }
        switch await group.nextResult(isolation: MainActor.shared) {
        case .success(let value):
            observations.append("success-" + value)
        case .failure:
            observations.append("unexpected-failure")
        case .none:
            observations.append("missing-success")
        }
        observations.append(group.isEmpty
            ? "success-consumed"
            : "success-pending")

        group.addTask {
            throw TaskGroupNextResultProbeError.child
        }
        switch await group.nextResult(isolation: MainActor.shared) {
        case .failure(let error):
            switch error {
            case TaskGroupNextResultProbeError.child:
                observations.append("failure-child")
            default:
                observations.append("failure-wrong-error")
            }
        case .success:
            observations.append("unexpected-success")
        case .none:
            observations.append("missing-failure")
        }
        observations.append(group.isEmpty && !group.isCancelled
            ? "failure-consumed-active"
            : "failure-state-wrong")

        group.cancelAll()
        group.addTask {
            try Task.checkCancellation()
            return "missed"
        }
        switch await group.nextResult(isolation: MainActor.shared) {
        case .failure(let error):
            let errorKind = type(of: error) == CancellationError.self
                ? "cancellation"
                : "wrong-cancellation-error"
            let ownerState = Task.isCancelled
                ? "owner-cancelled"
                : "owner-active"
            observations.append(errorKind + ":" + ownerState)
        case .success:
            observations.append("cancellation-missed")
        case .none:
            observations.append("missing-cancellation")
        }
        observations.append(group.isEmpty
            ? "cancellation-consumed"
            : "cancellation-pending")
    }

    let resumed = parityCurrentExecutorLane()
    return entered + "|" + observations.joined(separator: ",") + "|" + resumed
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupNextResultProbe()
}
