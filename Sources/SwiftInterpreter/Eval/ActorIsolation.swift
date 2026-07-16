extension Interpreter {
    enum RuntimeActorInvocationOwnership {
        case none
        case mailbox(RuntimeActorExecutorLease)
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

    /// Resolve dynamic isolation selected by a source function's `isolated`
    /// parameter. Argument matching happens before the hop, exactly as native
    /// Swift chooses the target executor from the call-site value. Static
    /// declaration/receiver isolation and dynamic parameter isolation are
    /// mutually exclusive source contracts.
    func resolvedExecutor(
        for closure: ClosureValue,
        arguments: CallArguments
    ) throws -> RuntimeExecutorKind? {
        let declarationExecutor = try resolvedExecutor(for: closure)
        let isolatedIndices = closure.parameters.indices.filter {
            closure.parameters[$0].isIsolated
        }
        guard !isolatedIndices.isEmpty else { return declarationExecutor }
        guard isolatedIndices.count == 1 else {
            throw RuntimeError(
                message: "a function may have only one isolated parameter",
                fatal: true)
        }
        guard declarationExecutor == nil else {
            throw RuntimeError(
                message: "isolated parameter conflicts with declaration "
                    + "executor isolation",
                fatal: true)
        }

        let index = isolatedIndices[0]
        let matched = matchedParameterArguments(
            of: closure, to: arguments)
        guard let argument = matched[index] else {
            throw RuntimeError(
                message: "isolated parameter '"
                    + closure.parameters[index].name
                    + "' requires an explicit runtime argument",
                fatal: true)
        }
        if argument.isNil { return nil }
        guard let value = argument.unwrappingInoutSlot.unwrappedOptionalOrSelf,
              case .instance(let actor) = value,
              actor.symbol.isActor,
              let actorID = actor.actorID else {
            throw RuntimeError(
                message: "isolated parameter '"
                    + closure.parameters[index].name
                    + "' requires a source actor instance",
                fatal: true)
        }
        return .actor(actorID)
    }

    /// A source actor's instance computed property is isolated to that exact
    /// actor unless the declaration is explicitly `nonisolated`. Accessor
    /// execution shares the same executor capability as an isolated method;
    /// it is not ordinary class-member evaluation.
    func resolvedExecutor(
        for computed: ComputedProperty,
        on instance: Instance
    ) throws -> RuntimeExecutorKind? {
        guard instance.symbol.isActor,
              !computed.isNonisolated,
              !instance.isInitializing,
              !evaluationTaskContext.initializingInstances.contains(
                ObjectIdentifier(instance)) else {
            return nil
        }
        guard let actorID = instance.actorID else {
            throw RuntimeError(
                message: "actor computed property requires a runtime actor ID",
                fatal: true)
        }
        return .actor(actorID)
    }

    /// A source actor's subscript accessor follows the same receiver-isolation
    /// rule as an instance computed property. An awaited getter's suspending
    /// expression path owns mailbox acquisition; every eager getter or setter
    /// may proceed only when the current task already owns the actor.
    func resolvedExecutor(
        for subscriptMember: StructSymbol.SubscriptMember,
        on instance: Instance
    ) throws -> RuntimeExecutorKind? {
        guard instance.symbol.isActor,
              !subscriptMember.isNonisolated,
              !instance.isInitializing,
              !evaluationTaskContext.initializingInstances.contains(
                ObjectIdentifier(instance)) else {
            return nil
        }
        guard let actorID = instance.actorID else {
            throw RuntimeError(
                message: "actor subscript requires a runtime actor ID",
                fatal: true)
        }
        return .actor(actorID)
    }

    /// Enter the source actor selected for a suspending invocation. Both sync
    /// and async declarations own a depth-counted mailbox segment; canonical
    /// runtime waits release the complete segment and restore it before the
    /// evaluator continues.
    func enterActorInvocation(
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
        return .mailbox(try await concurrencyRuntime.acquireActorExecutor(
            actorID, for: taskID))
    }

    func leaveActorInvocation(_ ownership: RuntimeActorInvocationOwnership) {
        switch ownership {
        case .none:
            break
        case .mailbox(let lease):
            concurrencyRuntime.releaseActorExecutor(lease)
        }
    }

    /// An awaited hop from actor A to a different explicit executor cannot
    /// retain A while entering the callee. Park A's complete nested segment;
    /// the caller restores it after the callee has released its own executor.
    func suspendCallerActorForExecutorHop(
        to calleeExecutor: RuntimeExecutorKind?
    ) -> RuntimeActorExecutorSuspension? {
        guard evaluationTaskContext.isAsyncSession,
              let calleeExecutor,
              calleeExecutor != evaluationTaskContext.currentExecutor,
              evaluationTaskContext.currentExecutor.actorID != nil,
              let taskID = evaluationTaskContext.runtimeTaskID else {
            return nil
        }
        return concurrencyRuntime.suspendOwnedActorExecutor(for: taskID)
    }

    /// A non-suspending evaluator entry may execute actor-isolated code only
    /// when the current source task already owns that actor. Cross-actor entry
    /// must use the suspending path so it can wait for the mailbox.
    func requireSynchronousActorInvocationAccess(
        to executor: RuntimeExecutorKind?
    ) throws {
        guard evaluationTaskContext.isAsyncSession,
              case .actor(let actorID)? = executor else { return }
        guard let taskID = evaluationTaskContext.runtimeTaskID,
              evaluationTaskContext.currentExecutor.actorID == actorID,
              concurrencyRuntime.actors[actorID]?.executorOwnerTaskID == taskID
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
        else {
            throw RuntimeError(
                message: "actor-isolated mutable property "
                    + "'\(instance.symbol.name).\(name)' accessed without "
                    + "owning its executor",
                fatal: true)
        }
    }
}
