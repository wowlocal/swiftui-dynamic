import Foundation

private enum SourceTaskGroupOutcomeConsumer {
    case scopeExit
    case waitForAll
}

extension Interpreter {
    func sourceTaskGroupFunction(
        kind: RuntimeTaskGroupKind
    ) -> HostFunction {
        let name = kind.sourceFunctionName
        return HostFunction(
            name: name,
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during task-group scope")
                }
                return try await withSourceTaskGroup(arguments, kind: kind)
            })
    }

    private func withSourceTaskGroup(
        _ arguments: CallArguments,
        kind: RuntimeTaskGroupKind
    ) async throws -> RuntimeValue {
        let name = kind.sourceFunctionName
        guard evaluationTaskContext.isAsyncSession,
              let ownerTaskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message:
                "\(name) requires an async runtime task")
        }
        guard arguments.labeled("of") != nil else {
            throw RuntimeError(message:
                "\(name) needs a child result type")
        }
        guard arguments.labeled("isolation") == nil else {
            throw RuntimeError(message:
                "\(name)(isolation:) is not supported yet")
        }
        guard let body = arguments.closure(labeled: "body")
                ?? arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "\(name) needs a body closure")
        }

        let record = concurrencyRuntime.createTaskGroup(
            ownerTaskID: ownerTaskID, kind: kind)
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
            try validateSourceTaskGroupOutcomes(
                outcomes, in: group, consumedBy: .scopeExit)
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
        case "isCancelled":
            try group.requireActive(
                ownerTaskID: evaluationTaskContext.runtimeTaskID)
            return .native(group.isCancellationRequested)

        case "addTask", "addTaskUnlessCancelled":
            let skipsCancelledGroup = name == "addTaskUnlessCancelled"
            return .hostFunction(HostFunction(name: name) {
                [weak self, weak group] arguments, _ in
                guard let self, let group else {
                    throw RuntimeError(message:
                        "task group was released before \(name)")
                }
                guard let operation = arguments.closure(labeled: "operation")
                        ?? arguments.firstUnlabeledClosure else {
                    throw RuntimeError(message:
                        "\(group.kind.sourceTypeName).\(name) needs an "
                        + "operation closure")
                }
                let priority = try RuntimeTaskPriority.sourceValue(
                    arguments.labeled("priority"))
                if skipsCancelledGroup {
                    try group.requireActive(
                        ownerTaskID: evaluationTaskContext.runtimeTaskID)
                    if group.isCancellationRequested {
                        return .native(false)
                    }
                }
                _ = try spawnTaskGroupChild(
                    operation: operation,
                    in: group,
                    priority: priority)
                if skipsCancelledGroup {
                    return .native(true)
                }
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
                    let outcomes = try await waitForAndConsumeSourceTaskGroup(
                        group)
                    try validateSourceTaskGroupOutcomes(
                        outcomes, in: group, consumedBy: .waitForAll)
                    return .void
                }))

        case "next":
            return .hostFunction(HostFunction(
                name: name,
                tracksHostOperation: false,
                asyncInvoke: { [weak self, weak group] _, _ in
                    guard let self, let group else {
                        throw RuntimeError(message:
                            "task group was released before next")
                    }
                    return try await nextSourceTaskGroupValue(group)
                }))

        case "cancelAll":
            return .hostFunction(HostFunction(name: name) {
                [weak self, weak group] _, _ in
                guard let self, let group else {
                    throw RuntimeError(message:
                        "task group was released before cancelAll")
                }
                try group.requireActive(
                    ownerTaskID: evaluationTaskContext.runtimeTaskID)
                group.requestCancelAll()
                cancelSourceTaskGroupChildren(
                    group, source: .taskGroupCancelAll)
                return .void
            })

        default:
            throw RuntimeError(message:
                "\(group.kind.sourceTypeName).\(name) is not supported yet")
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

    private func waitForAndConsumeSourceTaskGroup(
        _ group: RuntimeTaskGroup
    ) async throws -> [RuntimeTaskOutcome] {
        _ = try await waitForSourceTaskGroup(group)
        guard let ownerTaskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message:
                "task-group outcome consumption requires a runtime task")
        }

        var outcomes: [RuntimeTaskOutcome] = []
        while let outcome = await concurrencyRuntime.nextTaskGroupOutcome(
            ownerTaskID, on: group.record) {
            outcomes.append(outcome)
        }
        return outcomes
    }

    private func nextSourceTaskGroupValue(
        _ group: RuntimeTaskGroup
    ) async throws -> RuntimeValue {
        let ownerTaskID = evaluationTaskContext.runtimeTaskID
        try group.requireActive(ownerTaskID: ownerTaskID)
        guard let ownerTaskID else {
            throw RuntimeError(message:
                "task-group next requires a runtime task")
        }
        guard let outcome = await concurrencyRuntime.nextTaskGroupOutcome(
            ownerTaskID, on: group.record) else {
            return .none()
        }

        switch outcome {
        case .success(let value, let type):
            return .some(value, wrappedTypeName: type)
        case .failure(let value, _):
            switch group.kind {
            case .nonthrowing:
                throw RuntimeError(message:
                    "nonthrowing task-group child failed: \(value.stringified)")
            case .throwing:
                throw InterpretedThrow(value: value)
            }
        case .cancelled:
            switch group.kind {
            case .nonthrowing:
                throw RuntimeError(message:
                    "nonthrowing task-group child was cancelled without a value")
            case .throwing:
                throw RuntimeError(message:
                    "throwing task-group child cancellation propagation is not supported yet")
            }
        }
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
            cancelSourceTaskGroupChildren(
                group, source: .structuredScopeExit)
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

    private func cancelSourceTaskGroupChildren(
        _ group: RuntimeTaskGroup,
        source: RuntimeCancellationSource
    ) {
        for child in group.childHandles where !child.isCompleted {
            child.cancel(source: source)
        }
    }

    private func validateSourceTaskGroupOutcomes(
        _ outcomes: [RuntimeTaskOutcome],
        in group: RuntimeTaskGroup,
        consumedBy consumer: SourceTaskGroupOutcomeConsumer
    ) throws {
        let failures = outcomes.compactMap { outcome -> RuntimeValue? in
            guard case .failure(let value, _) = outcome else { return nil }
            return value
        }
        switch group.kind {
        case .nonthrowing:
            guard let failure = failures.first else { return }
            throw RuntimeError(message:
                "nonthrowing task-group child failed: \(failure.stringified)")

        case .throwing:
            switch consumer {
            case .scopeExit:
                guard !failures.isEmpty else { return }
                throw RuntimeError(message:
                    "throwing task-group scope-exit failure propagation "
                    + "is not supported yet")

            case .waitForAll:
                guard let firstError = outcomes.first(where: { outcome in
                    switch outcome {
                    case .success: false
                    case .failure, .cancelled: true
                    }
                }) else { return }
                switch firstError {
                case .failure(let value, _):
                    throw InterpretedThrow(value: value)
                case .cancelled:
                    throw CancellationError()
                case .success:
                    preconditionFailure(
                        "throwing wait selected a successful outcome as an error")
                }
            }
        }
    }
}
