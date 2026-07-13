import Foundation

extension Interpreter {
    func sourceTaskCancellationHandlerFunction() -> HostFunction {
        HostFunction(
            name: "withTaskCancellationHandler",
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during cancellation handler scope")
                }
                return try await withSourceTaskCancellationHandler(arguments)
            })
    }

    private func withSourceTaskCancellationHandler(
        _ arguments: CallArguments
    ) async throws -> RuntimeValue {
        guard evaluationTaskContext.isAsyncSession,
              let taskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message:
                "withTaskCancellationHandler requires an async runtime task")
        }
        guard arguments.labeled("isolation") == nil else {
            throw RuntimeError(message:
                "withTaskCancellationHandler(isolation:) is not supported yet")
        }
        guard let operation = arguments.closure(labeled: "operation")
                ?? arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "withTaskCancellationHandler needs an operation closure")
        }
        guard let handler = arguments.closure(labeled: "onCancel")
                ?? arguments.closure(labeled: "handler") else {
            throw RuntimeError(message:
                "withTaskCancellationHandler needs an onCancel closure")
        }

        let handlerID = concurrencyRuntime.addCancellationHandler(
            to: taskID
        ) { [weak self] in
            guard let self else {
                throw RuntimeError(message:
                    "interpreter was released while invoking cancellation handler")
            }
            // Deliberately retain the ambient evaluator task: native Swift
            // invokes onCancel synchronously in the task calling cancel(),
            // not as an async continuation of the cancelled operation.
            _ = try callWithArguments(
                handler, args: CallArguments(), node: nil)
        }
        defer {
            concurrencyRuntime.removeCancellationHandler(
                handlerID, from: taskID)
        }

        try concurrencyRuntime.throwCancellationHandlerFailure(for: taskID)
        return try await callWithArgumentsSuspending(
            operation, args: CallArguments(), node: nil)
    }
}
