import Foundation

extension Interpreter {
    func sourceTaskPriorityEscalationHandlerFunction(
        name: String = RuntimeConcurrencyFunctionIntrinsic
            .withTaskPriorityEscalationHandler.rawValue
    ) -> HostFunction {
        HostFunction(
            name: name,
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during priority escalation "
                            + "handler scope")
                }
                return try await withSourceTaskPriorityEscalationHandler(
                    named: name, arguments)
            })
    }

    private func withSourceTaskPriorityEscalationHandler(
        named sourceName: String,
        _ arguments: CallArguments
    ) async throws -> RuntimeValue {
        guard evaluationTaskContext.isAsyncSession,
              let taskID = evaluationTaskContext.runtimeTaskID else {
            throw RuntimeError(message:
                "withTaskPriorityEscalationHandler requires an async runtime "
                    + "task")
        }

        let declarations = GeneratedConcurrencySurface
            .topLevelFunctionDeclarations[sourceName, default: []]
        let hasIsolationParameter = declarations.contains { declaration in
            declaration.parameters.contains { $0.label == "isolation" }
        }
        if hasIsolationParameter {
            guard let isolation = arguments.labeled("isolation"),
                  isolation.isNil else {
                throw RuntimeError(message:
                    "\(sourceName)(isolation:) currently requires explicit nil")
            }
        } else if arguments.labeled("isolation") != nil {
            throw RuntimeError(message:
                "\(sourceName) does not accept isolation:")
        }

        guard let operation = arguments.closure(labeled: "operation")
                ?? arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "withTaskPriorityEscalationHandler needs an operation closure")
        }
        let labeledHandler = arguments.closure(
            labeled: "onPriorityEscalated")
        guard let handler = labeledHandler
                ?? arguments.lastUnlabeledClosure,
              labeledHandler != nil || handler !== operation else {
            throw RuntimeError(message:
                "withTaskPriorityEscalationHandler needs an "
                    + "onPriorityEscalated closure")
        }

        let handlerID = concurrencyRuntime.addPriorityEscalationHandler(
            to: taskID
        ) { [weak self] oldPriority, newPriority in
            guard let self else {
                throw RuntimeError(message:
                    "interpreter was released while invoking priority "
                        + "escalation handler")
            }
            // Retain the donating task's ambient evaluator context; only the
            // closure's lexical captures belong to the target task. Current
            // native Swift behaves this way, but parity deliberately makes no
            // callback-executor or physical-thread guarantee.
            _ = try callWithArguments(
                handler,
                args: CallArguments(arguments: [
                    .init(label: nil, value: .native(oldPriority)),
                    .init(label: nil, value: .native(newPriority)),
                ]),
                node: nil)
        }
        defer {
            concurrencyRuntime.removePriorityEscalationHandler(
                handlerID, from: taskID)
        }

        try concurrencyRuntime.throwPriorityEscalationHandlerFailure(
            for: taskID)
        do {
            let result = try await callWithArgumentsSuspending(
                operation, args: CallArguments(), node: nil)
            try concurrencyRuntime.throwPriorityEscalationHandlerFailure(
                for: taskID)
            return result
        } catch let operationError {
            try concurrencyRuntime.throwPriorityEscalationHandlerFailure(
                for: taskID)
            throw operationError
        }
    }
}
