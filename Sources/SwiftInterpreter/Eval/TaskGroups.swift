import Foundation

private enum SourceTaskGroupOutcomeConsumer: Equatable {
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
        guard !kind.requiresChildResultType
                || arguments.labeled("of") != nil else {
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
                if kind.discardsResults {
                    group.record.hasDiscardingBodyFailureExit = true
                }
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
        let typeName = group.kind.sourceTypeName
        guard let intrinsic = GeneratedConcurrencySurface.intrinsic(
            typeName: typeName, memberName: name
        ) else {
            let qualifier = GeneratedConcurrencySurface.knowsMember(
                typeName: typeName, memberName: name)
                ? " is declared by the active _Concurrency.swiftinterface but"
                : ""
            throw RuntimeError(message:
                "\(group.kind.sourceTypeName).\(name)\(qualifier) is not supported yet")
        }

        switch intrinsic {
        case .isCancelled:
            try group.requireActive(
                ownerTaskID: evaluationTaskContext.runtimeTaskID)
            return .native(group.isCancellationRequested)

        case .isEmpty:
            try group.requireActive(
                ownerTaskID: evaluationTaskContext.runtimeTaskID)
            return .native(group.record.isEmpty)

        case .addImmediateTask, .addImmediateTaskUnlessCancelled,
                .addTask, .addTaskUnlessCancelled:
            let skipsCancelledGroup = intrinsic == .addTaskUnlessCancelled
                || intrinsic == .addImmediateTaskUnlessCancelled
            let startsImmediately = intrinsic == .addImmediateTask
                || intrinsic == .addImmediateTaskUnlessCancelled
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
                let taskName = try RuntimeTaskName.sourceValue(
                    arguments.labeled("name"))
                if skipsCancelledGroup {
                    try group.requireActive(
                        ownerTaskID: evaluationTaskContext.runtimeTaskID)
                    if group.isCancellationRequested {
                        return .native(false)
                    }
                }
                try RuntimeTaskExecutorPreference.requireSupportedNil(
                    arguments.labeled("executorPreference"),
                    api: "\(group.kind.sourceTypeName).\(name)")
                _ = try spawnTaskGroupChild(
                    operation: operation,
                    in: group,
                    name: taskName,
                    priority: priority,
                    startsImmediately: startsImmediately)
                if skipsCancelledGroup {
                    return .native(true)
                }
                return .void
            })

        case .waitForAll:
            guard !group.kind.discardsResults else {
                throw RuntimeError(message:
                    "\(group.kind.sourceTypeName).waitForAll is not public")
            }
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

        case .next:
            guard !group.kind.discardsResults else {
                throw RuntimeError(message:
                    "\(group.kind.sourceTypeName).next is not public")
            }
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

        case .nextResult:
            guard group.kind == .throwing else {
                throw RuntimeError(message:
                    "\(group.kind.sourceTypeName).nextResult is not public")
            }
            return .hostFunction(HostFunction(
                name: name,
                tracksHostOperation: false,
                asyncInvoke: { [weak self, weak group] _, _ in
                    guard let self, let group else {
                        throw RuntimeError(message:
                            "task group was released before nextResult")
                    }
                    return try await nextSourceTaskGroupResult(group)
                }))

        case .makeAsyncIterator:
            guard !group.kind.discardsResults else {
                throw RuntimeError(message:
                    "\(group.kind.sourceTypeName).makeAsyncIterator is not public")
            }
            return .hostFunction(HostFunction(name: name) {
                [weak self, weak group] _, _ in
                guard let self, let group else {
                    throw RuntimeError(message:
                        "task group was released before makeAsyncIterator")
                }
                try group.requireActive(
                    ownerTaskID: evaluationTaskContext.runtimeTaskID)
                return .native(RuntimeTaskGroupIterator(group: group))
            })

        case .cancelAll:
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

        }
    }

    func sourceTaskGroupIteratorMember(
        _ name: String,
        on iterator: RuntimeTaskGroupIterator
    ) throws -> RuntimeValue? {
        let typeName = iterator.group.kind.sourceTypeName
        guard let intrinsic = GeneratedConcurrencySurface
            .taskGroupIteratorIntrinsic(
                typeName: typeName, memberName: name)
        else {
            guard GeneratedConcurrencySurface.knowsTaskGroupIteratorMember(
                typeName: typeName, memberName: name)
            else { return nil }
            throw RuntimeError(message:
                "\(typeName).Iterator.\(name) is declared by the active "
                    + "_Concurrency.swiftinterface but is not supported yet")
        }

        switch intrinsic {
        case .next:
            return .hostFunction(HostFunction(
                name: name,
                tracksHostOperation: false,
                asyncInvoke: { [weak self, weak iterator] _, _ in
                    guard let self, let iterator else {
                        throw RuntimeError(message:
                            "task-group iterator was released before next")
                    }
                    return try await nextSourceTaskGroupIteratorValue(iterator)
                }))

        case .cancel:
            return .hostFunction(HostFunction(name: name) {
                [weak self, weak iterator] _, _ in
                guard let self, let iterator else {
                    throw RuntimeError(message:
                        "task-group iterator was released before cancel")
                }
                let group = iterator.group
                try group.requireActive(
                    ownerTaskID: evaluationTaskContext.runtimeTaskID)
                iterator.markFinished()
                group.requestCancelAll()
                cancelSourceTaskGroupChildren(
                    group, source: .taskGroupCancelAll)
                return .void
            })
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
            if group.kind.isThrowing {
                throw InterpretedThrow(value: value)
            } else {
                throw RuntimeError(message:
                    "nonthrowing task-group child failed: \(value.stringified)")
            }
        case .cancelled:
            if group.kind.isThrowing {
                throw CancellationError()
            } else {
                throw RuntimeError(message:
                    "nonthrowing task-group child was cancelled without a value")
            }
        }
    }

    private func nextSourceTaskGroupIteratorValue(
        _ iterator: RuntimeTaskGroupIterator
    ) async throws -> RuntimeValue {
        let group = iterator.group
        try group.requireActive(
            ownerTaskID: evaluationTaskContext.runtimeTaskID)
        guard !iterator.isFinished else { return .none() }

        do {
            let next = try await nextSourceTaskGroupValue(group)
            guard case .optional(let optional) = next else {
                preconditionFailure("task-group next must return an Optional")
            }
            if optional.wrapped == nil {
                iterator.markFinished()
            }
            return next
        } catch {
            iterator.markFinished()
            throw error
        }
    }

    /// Consume one completion without projecting a throwing-group failure as
    /// control flow. `nextResult` is nonthrowing even when the child failed or
    /// observed cancellation; the exact stored source payload is retained in
    /// the same Result carrier used by `Task.result`.
    private func nextSourceTaskGroupResult(
        _ group: RuntimeTaskGroup
    ) async throws -> RuntimeValue {
        let ownerTaskID = evaluationTaskContext.runtimeTaskID
        try group.requireActive(ownerTaskID: ownerTaskID)
        guard let ownerTaskID else {
            throw RuntimeError(message:
                "task-group nextResult requires a runtime task")
        }
        guard let outcome = await concurrencyRuntime.nextTaskGroupOutcome(
            ownerTaskID, on: group.record) else {
            return .none()
        }
        return .some(.native(RuntimeResultValue(taskOutcome: outcome)))
    }

    /// Consume one source-facing async-sequence element from an active group.
    /// Keeping iteration on the same path as `group.next()` preserves the
    /// completion queue's ordering, ownership checks, and exactly-once result
    /// consumption.
    func nextSourceTaskGroupIterationValue(
        _ group: RuntimeTaskGroup
    ) async throws -> RuntimeValue? {
        let next = try await nextSourceTaskGroupValue(group)
        guard case .optional(let optional) = next else {
            preconditionFailure("task-group next must return an Optional")
        }
        return optional.wrapped
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
        switch group.kind {
        case .nonthrowing:
            let failures = outcomes.compactMap { outcome -> RuntimeValue? in
                guard case .failure(let value, _) = outcome else { return nil }
                return value
            }
            guard let failure = failures.first else { return }
            throw RuntimeError(message:
                "nonthrowing task-group child failed: \(failure.stringified)")

        case .throwing:
            switch consumer {
            case .scopeExit:
                // A normal `withThrowingTaskGroup` body return only joins and
                // destroys outstanding children. Child errors are observable
                // through `next`/`waitForAll`; implicit cleanup does not
                // consume or rethrow them.
                return

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

        case .discarding:
            guard let failure = group.record.firstDiscardingFailure else {
                return
            }
            switch failure {
            case .failure(let value, _):
                throw RuntimeError(message:
                    "nonthrowing discarding task-group child failed: "
                        + value.stringified)
            case .cancelled:
                throw RuntimeError(message:
                    "nonthrowing discarding task-group child was cancelled "
                        + "without a value")
            case .success:
                preconditionFailure(
                    "discarding group retained a successful outcome as failure")
            }

        case .throwingDiscarding:
            precondition(
                consumer == .scopeExit,
                "throwing discarding group has no public waitForAll")
            guard let failure = group.record.firstDiscardingFailure else {
                return
            }
            switch failure {
            case .failure(let value, _):
                throw InterpretedThrow(value: value)
            case .cancelled:
                throw CancellationError()
            case .success:
                preconditionFailure(
                    "throwing discarding group retained success as failure")
            }
        }
    }
}
