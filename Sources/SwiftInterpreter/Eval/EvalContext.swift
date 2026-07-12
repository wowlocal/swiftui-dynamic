/// A host-call capability bound to the source task that entered the gateway.
/// Hosts may retain it and re-enter from a newly-created native task; every
/// callback is rebound to the original evaluator context instead of relying
/// on ambient native TaskLocal inheritance.
final class TaskBoundEvalContext: EvalContext {
    let interpreter: Interpreter
    let evaluationContext: EvaluationTaskContext

    init(interpreter: Interpreter, evaluationContext: EvaluationTaskContext) {
        self.interpreter = interpreter
        self.evaluationContext = evaluationContext
    }

    var evaluationTaskContextID: UInt64 { evaluationContext.id }

    private func bound<T>(_ operation: () throws -> T) rethrows -> T {
        try EvaluationTaskContext.$current.withValue(
            evaluationContext, operation: operation)
    }

    private func bound<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await EvaluationTaskContext.$current.withValue(evaluationContext) {
            try await operation()
        }
    }

    func callClosure(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.callClosure(closure, arguments: arguments)
        }
    }

    func callClosureAsync(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        try await bound {
            try await interpreter.callClosureAsync(
                closure, arguments: arguments)
        }
    }

    func spawnBackgroundTask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.spawnBackgroundTask(closure, arguments: arguments)
        }
    }

    func invokeHostConstructor(
        named name: String, arguments: CallArguments
    ) throws -> RuntimeValue? {
        try bound {
            try interpreter.invokeHostConstructor(named: name, arguments: arguments)
        }
    }

    func callBackgroundClosure(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try bound {
            try interpreter.callBackgroundClosure(closure, arguments: arguments)
        }
    }

    func callBuilderClosure(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> [RuntimeValue] {
        try bound {
            try interpreter.callBuilderClosure(closure, arguments: arguments)
        }
    }

    func hostTypeName(of value: RuntimeValue) -> String {
        bound { interpreter.hostTypeName(of: value) }
    }

    func hostValue(
        _ value: RuntimeValue, matchesType typeName: String
    ) -> Bool {
        bound { interpreter.hostValue(value, matchesType: typeName) }
    }

    func hostValue(
        _ value: RuntimeValue, conformsTo protocolName: String
    ) -> Bool {
        bound { interpreter.hostValue(value, conformsTo: protocolName) }
    }
}

// MARK: - EvalContext (what gateways can call back into)

extension Interpreter: EvalContext {
    public func hostTypeName(of value: RuntimeValue) -> String {
        if case .host(let any) = value {
            if let marker = any as? HostTypeMarker { return marker.name + ".Type" }
            if let typeName = registry?.hostTypeName(of: any) { return typeName }
        }
        return HostRuntimeTypeSystem.typeName(of: value)
    }

    public func hostValue(
        _ value: RuntimeValue, matchesType typeName: String
    ) -> Bool {
        HostRuntimeTypeSystem.matches(value, type: typeName)
            || valueIsType(value, typeName)
    }

    public func hostValue(
        _ value: RuntimeValue, conformsTo protocolName: String
    ) -> Bool {
        if HostRuntimeTypeSystem.conforms(value, to: protocolName)
            || valueIsType(value, protocolName) {
            return true
        }
        if case .host(let any) = value {
            return registry?.hostProtocolCandidates(of: any)
                .contains(protocolName) == true
        }
        return false
    }

    public func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        steps = 0 // fresh entry, e.g. a Button action invoked from the UI
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        return try callWithArguments(closure, args: args, node: nil)
    }

    public func callClosureAsync(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        steps = 0
        let args = CallArguments(arguments: arguments.map {
            .init(label: nil, value: $0)
        })
        return try await callWithArgumentsSuspending(closure, args: args, node: nil)
    }

    public func spawnBackgroundTask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        let handle = RuntimeTaskHandle()
        let arguments = arguments

        // Existing synchronous clients cannot suspend to await child work.
        // Preserve their deterministic contract while returning the same
        // observable handle used by async sessions.
        guard asyncSessionDepth > 0 else {
            // Compatibility runs historically execute one task body inline
            // but suppress recursively-created tasks. Without this guard,
            // each nested body resets its background slice and can evade the
            // evaluator budget indefinitely.
            guard synchronousTaskDepth == 0 else {
                handle.succeed(with: .void)
                return .native(handle)
            }
            synchronousTaskDepth += 1
            defer { synchronousTaskDepth -= 1 }
            do {
                let value = try callBackgroundClosure(closure, arguments: arguments)
                handle.succeed(with: value)
            } catch is CancellationError {
                handle.cancel()
                throw CancellationError()
            } catch let error as RuntimeError where !error.fatal {
                handle.fail(with: error)
            }
            return .native(handle)
        }

        guard scheduledTasks.count < scheduledTaskLimit else {
            throw RuntimeError(
                message: "interpreted task limit exceeded", fatal: true)
        }

        let taskContext = makeEvaluationTaskContext()
        let task = Task { @MainActor [weak self, weak handle] in
            await EvaluationTaskContext.$current.withValue(taskContext) {
                defer { taskContext.removeAllDynamicState() }
                // A newly-created Task never runs inline with its constructor.
                await Task.yield()
                guard let self, let handle else { return }
                guard !Task.isCancelled, handle.begin() else {
                    handle.cancel()
                    return
                }
                do {
                    let value = try await self.callBackgroundClosureSuspending(
                        closure, arguments: arguments)
                    try Task.checkCancellation()
                    handle.succeed(with: value)
                } catch is CancellationError {
                    handle.cancel()
                } catch {
                    handle.fail(with: error)
                }
            }
        }
        handle.attach(task)
        scheduledTasks.append(handle)
        return .native(handle)
    }

    public func invokeHostConstructor(
        named name: String, arguments: CallArguments
    ) throws -> RuntimeValue? {
        guard let constructor = registry?.constructor(named: name) else { return nil }
        return try constructor.invoke(arguments, self)
    }

    /// Background work (`Task { … }` bodies). On device these run
    /// concurrently, so an INTENTIONALLY infinite loop (`while true {
    /// poll(); try? await Task.sleep }`) is legitimate there — it suspends
    /// and never blocks launch. Synchronously we give the body a bounded
    /// slice and PARK it when the slice is spent: execution stops quietly
    /// and the caller's own budget is untouched. Documented divergence:
    /// parked background tasks never resume.
    public func callBackgroundClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        let entrySteps = steps
        let slice = 20_000
        steps = max(0, stepBudget - slice)
        defer { steps = entrySteps }
        do {
            let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
            return try callWithArguments(closure, args: args, node: nil)
        } catch let error as RuntimeError where error.budgetTrip {
            return .void // parked
        }
    }

    /// Async-session task bodies share the same bounded evaluator budget but
    /// keep suspension propagation intact. Cancellation is polled before and
    /// after every host await and at every statement/loop boundary.
    func callBackgroundClosureSuspending(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        let entrySteps = steps
        let slice = 20_000
        steps = max(0, stepBudget - slice)
        defer { steps = entrySteps }
        do {
            let args = CallArguments(arguments: arguments.map {
                .init(label: nil, value: $0)
            })
            return try await callWithArgumentsSuspending(
                closure, args: args, node: nil)
        } catch let error as RuntimeError where error.budgetTrip {
            return .void
        }
    }

    public func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue] {
        let env = Environment(parent: closure.captured)
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        try bindParameters(of: closure, to: args, into: env, node: nil)
        return try collectBuilderViews(closure.body, in: env)
    }
}
