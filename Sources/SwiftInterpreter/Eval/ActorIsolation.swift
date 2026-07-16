extension Interpreter {
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
}
