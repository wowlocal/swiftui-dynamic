import Foundation

extension Interpreter {
    func sourceTaskGroupFunction() -> HostFunction {
        HostFunction(
            name: "withTaskGroup",
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during task-group scope")
                }
                return try await withSourceTaskGroup(arguments)
            })
    }

    private func withSourceTaskGroup(
        _ arguments: CallArguments
    ) async throws -> RuntimeValue {
        guard evaluationTaskContext.isAsyncSession,
              let ownerTaskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message:
                "withTaskGroup requires an async runtime task")
        }
        guard arguments.labeled("of") != nil else {
            throw RuntimeError(message:
                "withTaskGroup needs a child result type")
        }
        guard arguments.labeled("isolation") == nil else {
            throw RuntimeError(message:
                "withTaskGroup(isolation:) is not supported yet")
        }
        guard let body = arguments.closure(labeled: "body")
                ?? arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "withTaskGroup needs a body closure")
        }

        let record = concurrencyRuntime.createTaskGroup(
            ownerTaskID: ownerTaskID)
        let group = RuntimeTaskGroup(record: record)
        do {
            let result = try await callWithArgumentsSuspending(
                body,
                args: CallArguments(arguments: [
                    .init(label: nil, value: .native(group)),
                ]),
                node: nil)

            let outcomes = await closeSourceTaskGroup(
                group, cancelRemaining: false)
            try throwNonthrowingGroupFailure(outcomes)
            return result
        } catch {
            if !group.isClosed {
                _ = await closeSourceTaskGroup(
                    group, cancelRemaining: true)
            }
            throw error
        }
    }

    func sourceTaskGroupMember(
        _ name: String,
        on group: RuntimeTaskGroup
    ) throws -> RuntimeValue {
        switch name {
        case "addTask":
            return .hostFunction(HostFunction(name: name) {
                [weak self, weak group] arguments, _ in
                guard let self, let group else {
                    throw RuntimeError(message:
                        "task group was released before addTask")
                }
                guard let operation = arguments.closure(labeled: "operation")
                        ?? arguments.firstUnlabeledClosure else {
                    throw RuntimeError(message:
                        "TaskGroup.addTask needs an operation closure")
                }
                _ = try spawnTaskGroupChild(
                    operation: operation,
                    in: group,
                    priority: RuntimeTaskPriority.sourceValue(
                        arguments.labeled("priority")))
                return .void
            })

        case "waitForAll":
            return .hostFunction(HostFunction(
                name: name,
                tracksHostOperation: false,
                asyncInvoke: { [weak self, weak group] _, _ in
                    guard let self, let group else {
                        throw RuntimeError(message:
                            "task group was released before waitForAll")
                    }
                    let outcomes = try await waitForSourceTaskGroup(group)
                    try throwNonthrowingGroupFailure(outcomes)
                    return .void
                }))

        default:
            throw RuntimeError(message:
                "TaskGroup.\(name) is not supported yet")
        }
    }

    private func waitForSourceTaskGroup(
        _ group: RuntimeTaskGroup
    ) async throws -> [RuntimeTaskOutcome] {
        let ownerTaskID = evaluationTaskContext.runtimeTaskID
        try group.requireActive(ownerTaskID: ownerTaskID)
        guard let ownerTaskID else {
            throw RuntimeError(message:
                "task-group wait requires a runtime task")
        }

        return await waitForSourceTaskGroupChildren(
            group, ownerTaskID: ownerTaskID)
    }

    private func waitForSourceTaskGroupChildren(
        _ group: RuntimeTaskGroup,
        ownerTaskID: RuntimeTaskID
    ) async -> [RuntimeTaskOutcome] {
        precondition(
            !group.isClosed && group.ownerTaskID == ownerTaskID,
            "task-group cleanup must run in its owning task")

        let suspension = concurrencyRuntime.beginWaitingForTaskGroup(
            ownerTaskID, on: group.record)
        defer {
            concurrencyRuntime.endWaitingForTaskGroup(
                ownerTaskID,
                on: group.record,
                from: suspension)
        }
        for child in group.childHandles {
            await child.wait()
        }
        return group.childHandles.compactMap(\.outcome)
    }

    private func closeSourceTaskGroup(
        _ group: RuntimeTaskGroup,
        cancelRemaining: Bool
    ) async -> [RuntimeTaskOutcome] {
        guard !group.isClosed else { return [] }
        if cancelRemaining {
            for child in group.childHandles where !child.isCompleted {
                child.cancel(source: .structuredScopeExit)
            }
        }

        guard let ownerTaskID = evaluationTaskContext.runtimeTaskID else {
            preconditionFailure(
                "task-group cleanup lost its runtime task")
        }
        let outcomes = await waitForSourceTaskGroupChildren(
            group, ownerTaskID: ownerTaskID)
        let handles = group.childHandles
        concurrencyRuntime.closeTaskGroup(group.record)
        for child in handles {
            concurrencyRuntime.release(child.id)
        }
        group.close()
        return outcomes
    }

    private func throwNonthrowingGroupFailure(
        _ outcomes: [RuntimeTaskOutcome]
    ) throws {
        for outcome in outcomes {
            guard case .failure(let value, _) = outcome else { continue }
            throw RuntimeError(message:
                "nonthrowing task-group child failed: \(value.stringified)")
        }
    }
}
