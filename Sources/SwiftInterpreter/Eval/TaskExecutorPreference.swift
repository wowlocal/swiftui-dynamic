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
        guard let operationArgument = arguments.arguments.first(where: {
                $0.label == "operation" && $0.value.closureValue != nil
            }) ?? arguments.arguments.last(where: {
                $0.label == nil && $0.value.closureValue != nil
            }),
              let operation = operationArgument.value.closureValue else {
            throw RuntimeError(message:
                "withTaskExecutorPreference needs an operation closure")
        }
        guard operationArgument.sourceProvenance
                == .directGlobalAsyncFunctionDeclaration,
              operation.isExplicitlyNonisolated,
              operation.executorPreference == nil else {
            throw RuntimeError(message:
                "withTaskExecutorPreference currently requires a bare "
                    + "unqualified direct global operation function "
                    + "explicitly declared nonisolated and async with no "
                    + "executor preference")
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
