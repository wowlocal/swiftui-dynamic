extension Interpreter {
    enum RuntimeActorInvocationOwnership {
        case none
        case mailbox(RuntimeActorExecutorLease)
        case asyncCompatibility(RuntimeActorID)
    }

    /// Resolve declaration isolation at invocation, after every source type
    /// has been collected. User-defined global actors are represented by the
    /// actor instance returned from their canonical `static shared` member,
    /// so ordinary actor calls, global-actor calls, and `#isolation` all use
    /// one `RuntimeActorID` identity.
    func resolvedExecutor(
        for closure: ClosureValue
    ) throws -> RuntimeExecutorKind? {
        if let executor = closure.executorPreference {
            return executor
        }

        for candidate in closure.globalActorAttributeCandidates {
            guard case .type(let symbol)? = globals.lookup(candidate),
                  symbol.attributeNames.contains("globalActor") else {
                continue
            }
            guard let shared = try staticMember("shared", of: symbol),
                  case .instance(let actor) = shared,
                  actor.symbol.isActor,
                  let actorID = actor.actorID else {
                throw RuntimeError(message:
                    "global actor '\(symbol.name)' must expose a source "
                        + "actor instance as static shared")
            }
            return .actor(actorID)
        }
        return nil
    }

    /// Enter the source actor selected for a suspending invocation. A
    /// synchronous declaration owns the mailbox until its body returns. Async
    /// declarations remain on an explicit compatibility frame until the next
    /// slice can release at each suspension and reacquire before resumption.
    func enterActorInvocation(
        closure: ClosureValue,
        executor: RuntimeExecutorKind?
    ) async throws -> RuntimeActorInvocationOwnership {
        guard evaluationTaskContext.isAsyncSession,
              case .actor(let actorID)? = executor else {
            return .none
        }
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(
                message: "actor-isolated invocation requires a runtime task",
                fatal: true)
        }
        if closure.isAsyncFunction {
            evaluationTaskContext.unownedAsyncActorCompatibilityFrames.append(
                actorID)
            return .asyncCompatibility(actorID)
        }
        return .mailbox(try await concurrencyRuntime.acquireActorExecutor(
            actorID, for: taskID))
    }

    func leaveActorInvocation(_ ownership: RuntimeActorInvocationOwnership) {
        switch ownership {
        case .none:
            break
        case .mailbox(let lease):
            concurrencyRuntime.releaseActorExecutor(lease)
        case .asyncCompatibility(let actorID):
            precondition(
                evaluationTaskContext.unownedAsyncActorCompatibilityFrames.last
                    == actorID,
                "async actor compatibility frames left out of order")
            evaluationTaskContext.unownedAsyncActorCompatibilityFrames.removeLast()
        }
    }

    /// A non-suspending evaluator entry may execute actor-isolated code only
    /// when the current source task already owns that actor (or is inside the
    /// explicit async compatibility frame). Cross-actor entry must use the
    /// suspending path so it can wait for the mailbox.
    func requireSynchronousActorInvocationAccess(
        to executor: RuntimeExecutorKind?
    ) throws {
        guard evaluationTaskContext.isAsyncSession,
              case .actor(let actorID)? = executor else { return }
        guard let taskID = evaluationTaskContext.runtimeTaskID,
              evaluationTaskContext.currentExecutor.actorID == actorID,
              concurrencyRuntime.actors[actorID]?.executorOwnerTaskID == taskID
                || evaluationTaskContext
                    .unownedAsyncActorCompatibilityFrames.contains(actorID)
        else {
            throw RuntimeError(
                message: "cross-actor synchronous call requires an awaited "
                    + "actor-executor entry",
                fatal: true)
        }
    }

    /// Enforce mutable actor-storage confinement at the common property
    /// read/write funnels. Swift permits ordinary immutable actor `let` reads
    /// from outside the actor, and explicitly nonisolated storage does not use
    /// this mailbox guard.
    func requireActorStoredPropertyAccess(
        _ instance: Instance,
        property name: String
    ) throws {
        guard instance.symbol.isActor,
              let property = instance.symbol.storedProperty(named: name),
              property.requiresActorExecutor,
              !instance.isInitializing,
              !evaluationTaskContext.initializingInstances.contains(
                ObjectIdentifier(instance)),
              evaluationTaskContext.isAsyncSession else { return }
        guard let actorID = instance.actorID,
              evaluationTaskContext.currentExecutor.actorID == actorID,
              let taskID = evaluationTaskContext.runtimeTaskID,
              concurrencyRuntime.actors[actorID]?.executorOwnerTaskID == taskID
                || evaluationTaskContext
                    .unownedAsyncActorCompatibilityFrames.contains(actorID)
        else {
            throw RuntimeError(
                message: "actor-isolated mutable property "
                    + "'\(instance.symbol.name).\(name)' accessed without "
                    + "owning its executor",
                fatal: true)
        }
    }
}
