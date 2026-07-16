import Foundation

extension Interpreter {
    func sourceTaskExecutorPreferenceFunction(
        name: String = RuntimeConcurrencyFunctionIntrinsic
            .withTaskExecutorPreference.rawValue
    ) -> HostFunction {
        HostFunction(
            name: name,
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during task-executor "
                            + "preference scope")
                }
                return try await withSourceTaskExecutorPreference(
                    named: name, arguments)
            })
    }

    private func withSourceTaskExecutorPreference(
        named sourceName: String,
        _ arguments: CallArguments
    ) async throws -> RuntimeValue {
        _ = try requireCanonicalActiveRuntimeTask(for: sourceName)
        guard let taskExecutor = arguments.positional(0) else {
            throw RuntimeError(message:
                "withTaskExecutorPreference requires an explicit task "
                    + "executor argument")
        }
        guard taskExecutor.isNil else {
            throw RuntimeError(message:
                "\(sourceName) currently requires an explicit nil task "
                    + "executor")
        }
        guard let isolation = arguments.labeled("isolation"),
              isolation.isNil else {
            throw RuntimeError(message:
                "withTaskExecutorPreference(isolation:) currently requires "
                    + "explicit nil")
        }
        guard let operation = arguments.closure(labeled: "operation")
                ?? arguments.lastUnlabeledClosure else {
            throw RuntimeError(message:
                "withTaskExecutorPreference needs an operation closure")
        }
        guard operation.functionDeclID != nil,
              operation.isExplicitlyNonisolated,
              operation.executorPreference == nil else {
            throw RuntimeError(message:
                "withTaskExecutorPreference currently requires an operation "
                    + "function explicitly declared nonisolated")
        }

        // In the supported subset there is no ambient custom TaskExecutor and
        // the requested preference is explicitly nil. Native Swift therefore
        // keeps the operation in the current logical task. Do not create a
        // child task or alter its task locals, priority, cancellation, name,
        // or executor identity around the suspending call.
        return try await callWithArgumentsSuspending(
            operation, args: CallArguments(), node: nil)
    }
}
