// MARK: - EvalContext (what gateways can call back into)

extension Interpreter: EvalContext {
    public func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        steps = 0 // fresh entry, e.g. a Button action invoked from the UI
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        return try callWithArguments(closure, args: args, node: nil)
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

        let task = Task { @MainActor [weak self, weak handle] in
            // A newly-created Task never runs inline with its constructor.
            await Task.yield()
            guard let self, let handle else { return }
            guard !Task.isCancelled, handle.begin() else {
                handle.cancel()
                return
            }
            do {
                let value = try self.callBackgroundClosure(closure, arguments: arguments)
                try Task.checkCancellation()
                handle.succeed(with: value)
            } catch is CancellationError {
                handle.cancel()
            } catch {
                handle.fail(with: error)
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

    public func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue] {
        let env = Environment(parent: closure.captured)
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        try bindParameters(of: closure, to: args, into: env, node: nil)
        return try collectBuilderViews(closure.body, in: env)
    }
}
