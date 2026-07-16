extension Interpreter {
    /// One generated top-level route serves both the synchronous and
    /// asynchronous stdlib overloads. The capability argument is tied to the
    /// current logical runtime task and its lease ends with the body call.
    func sourceCurrentTaskCapabilityFunction(
        name: String = RuntimeConcurrencyFunctionIntrinsic
            .withCurrentTaskCapability.rawValue
    ) -> HostFunction {
        HostFunction(
            name: name,
            invoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during withUnsafeCurrentTask")
                }
                return try withSourceCurrentTaskCapability(arguments)
            },
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during withUnsafeCurrentTask")
                }
                return try await withSourceCurrentTaskCapabilitySuspending(
                    arguments)
            })
    }

    private func withSourceCurrentTaskCapability(
        _ arguments: CallArguments
    ) throws -> RuntimeValue {
        let body = try currentTaskCapabilityBody(arguments)
        let argument = try currentTaskCapabilityArgument()
        defer { argument.lease?.invalidate() }
        return try callWithArguments(
            body,
            args: CallArguments(arguments: [
                .init(label: nil, value: argument.value),
            ]),
            node: nil)
    }

    private func withSourceCurrentTaskCapabilitySuspending(
        _ arguments: CallArguments
    ) async throws -> RuntimeValue {
        let body = try currentTaskCapabilityBody(arguments)
        let argument = try currentTaskCapabilityArgument()
        defer { argument.lease?.invalidate() }
        return try await callWithArgumentsSuspending(
            body,
            args: CallArguments(arguments: [
                .init(label: nil, value: argument.value),
            ]),
            node: nil)
    }

    private func currentTaskCapabilityBody(
        _ arguments: CallArguments
    ) throws -> ClosureValue {
        guard let body = arguments.closure(labeled: "body")
                ?? arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "withUnsafeCurrentTask needs a body closure")
        }
        return body
    }

    private func currentTaskCapabilityArgument() throws -> (
        value: RuntimeValue,
        lease: RuntimeUnsafeCurrentTaskLease?
    ) {
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            return (
                .none(wrappedTypeName: "UnsafeCurrentTask"),
                nil)
        }
        guard evaluationTaskContext.isAsyncSession,
              concurrencyRuntime.records[taskID] != nil else {
            throw RuntimeError(message:
                "current logical task is not active in the concurrency runtime")
        }
        let lease = RuntimeUnsafeCurrentTaskLease()
        let capability = RuntimeUnsafeCurrentTask(
            runtime: concurrencyRuntime,
            taskID: taskID,
            lease: lease)
        return (
            .some(.native(capability), wrappedTypeName: "UnsafeCurrentTask"),
            lease)
    }
}
