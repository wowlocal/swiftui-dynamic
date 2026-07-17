/// The source token is a small capability over a runtime-owned continuation
/// record. It deliberately retains only the record identity after completion;
/// an escaped token cannot keep its task, session, or interpreter alive.
final class RuntimeCheckedContinuation: RuntimeConcurrencyHostValue {
    weak var runtime: CooperativeConcurrencyRuntime?
    let id: RuntimeContinuationID
    let allowsThrowingResume: Bool
    private let function: String
    private let diagnostics: RuntimeDiagnosticSink
    private var didResume = false
    private var wasInfrastructureAborted = false

    init(
        runtime: CooperativeConcurrencyRuntime,
        id: RuntimeContinuationID,
        allowsThrowingResume: Bool,
        function: String
    ) {
        self.runtime = runtime
        self.id = id
        self.allowsThrowingResume = allowsThrowingResume
        self.function = function
        diagnostics = runtime.diagnostics
    }

    deinit {
        guard !didResume, !wasInfrastructureAborted else { return }
        diagnostics.emitWarning(
            "SWIFT TASK CONTINUATION MISUSE: \(function) leaked its "
                + "continuation without resuming it. This may cause tasks "
                + "waiting on it to remain suspended forever.")
    }

    var sourceTypeName: String { "CheckedContinuation" }
    var sourceProtocolNames: [String] { [] }

    func invalidateForInfrastructureAbort() {
        wasInfrastructureAborted = true
    }

    func resume(returning value: RuntimeValue) throws {
        guard !didResume else {
            throw RuntimeError(
                message: "checked continuation \(id) resumed more than once",
                fatal: true)
        }
        guard let runtime else {
            throw RuntimeError(
                message: "checked continuation \(id) outlived its runtime",
                fatal: true)
        }
        try runtime.resumeContinuation(id, returning: value)
        didResume = true
    }

    func resume(throwing value: RuntimeValue) throws {
        guard allowsThrowingResume else {
            throw RuntimeError(message:
                "nonthrowing checked continuation cannot resume with an error")
        }
        guard !didResume else {
            throw RuntimeError(
                message: "checked continuation \(id) resumed more than once",
                fatal: true)
        }
        guard let runtime else {
            throw RuntimeError(
                message: "checked continuation \(id) outlived its runtime",
                fatal: true)
        }
        try runtime.resumeContinuation(id, throwing: value)
        didResume = true
    }

    func resume(with result: RuntimeValue) throws {
        // Compiler preflight proves the nominal Swift.Result constraint. The
        // evaluator's imported-enum carrier preserves its case and payload.
        guard case .host(let payload) = result,
              let shaped = payload as? CaseShaped else {
            throw RuntimeError(message:
                "CheckedContinuation.resume(with:) requires a Result value")
        }
        let values = shaped.casePayloads
        guard values.count == 1 else {
            throw RuntimeError(message:
                "CheckedContinuation.resume(with:) requires a Result value")
        }
        let value = values[0]
        switch shaped.caseName {
        case "success":
            try resume(returning: value)
        case "failure":
            try resume(throwing: value)
        default:
            throw RuntimeError(message:
                "CheckedContinuation.resume(with:) requires a Result value")
        }
    }
}

enum RuntimeContinuationState {
    case pending
    case resumed(RuntimeValue)
    case failed(RuntimeValue)
    case aborted
}

/// Mutable continuation lifecycle owned by `CooperativeConcurrencyRuntime`
/// and linked from exactly one source task while active.
final class RuntimeContinuationRecord {
    let id: RuntimeContinuationID
    let ownerTaskID: RuntimeTaskID
    let requiredExecutor: RuntimeExecutorKind
    var state: RuntimeContinuationState = .pending
    var nativeWaiter: CheckedContinuation<Void, Never>?
    var suspensionLease: RuntimeTaskSuspensionLease?
    weak var sourceToken: RuntimeCheckedContinuation?

    init(
        id: RuntimeContinuationID,
        ownerTaskID: RuntimeTaskID,
        requiredExecutor: RuntimeExecutorKind
    ) {
        self.id = id
        self.ownerTaskID = ownerTaskID
        self.requiredExecutor = requiredExecutor
    }
}

extension Interpreter {
    func sourceCheckedContinuationFunction(
        name: String = RuntimeConcurrencyFunctionIntrinsic
            .withCheckedContinuation.rawValue,
        allowsThrowingResume: Bool = false
    ) -> HostFunction {
        HostFunction(
            name: name,
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during checked continuation")
                }
                return try await withSourceCheckedContinuation(
                    arguments,
                    api: name,
                    allowsThrowingResume: allowsThrowingResume)
            })
    }

    private func withSourceCheckedContinuation(
        _ arguments: CallArguments,
        api: String,
        allowsThrowingResume: Bool
    ) async throws -> RuntimeValue {
        let task = try requireCanonicalActiveRuntimeTask(
            for: api)
        // Swift's default is `#isolation`, evaluated once in the caller's
        // lexical source isolation. Reuse the same materialization kernel as
        // defaulted isolated parameters instead of treating omission as nil:
        // MainActor callers must retain MainActor, while nonisolated callers
        // produce the optional-none value.
        let isolation = try arguments.labeled("isolation")
            ?? currentSourceIsolationValue()
        let bodyExecutor: RuntimeExecutorKind?
        if isolation.isNil {
            bodyExecutor = nil
        } else {
            guard let actor = isolation.unwrappingInoutSlot
                    .unwrappedOptionalOrSelf,
                  !actor.isNil else {
                throw RuntimeError(message:
                    "\(api) isolation requires an actor")
            }
            let executor = try executorSelectedByIsolatedValue(
                actor, parameterName: "isolation")
            bodyExecutor = executor
        }
        let function: String
        if let suppliedFunction = arguments.labeled("function") {
            guard let string = suppliedFunction.stringValue else {
                throw RuntimeError(message:
                    "\(api)(function:) requires a String")
            }
            function = string
        } else {
            function = api
        }
        guard let body = arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "\(api) needs a body closure")
        }

        let record = try concurrencyRuntime.createContinuation(
            ownerTaskID: task.id,
            requiredExecutor: evaluationTaskContext.currentExecutor)
        var continuation: RuntimeCheckedContinuation? = RuntimeCheckedContinuation(
            runtime: concurrencyRuntime,
            id: record.id,
            allowsThrowingResume: allowsThrowingResume,
            function: function)
        record.sourceToken = continuation
        do {
            guard let continuation else {
                preconditionFailure("\(record.id) lost its source token")
            }
            _ = try await callWithArgumentsSuspending(
                body,
                args: CallArguments(arguments: [
                    .init(label: nil, value: .native(continuation))
                ]),
                node: nil,
                contextualExecutor: bodyExecutor)
        } catch {
            continuation?.invalidateForInfrastructureAbort()
            continuation = nil
            concurrencyRuntime.discardContinuation(record)
            throw error
        }
        // Release the runtime's body-local source capability before parking.
        // If source did not escape it, the final release emits Swift's checked
        // abandonment warning; an escaped copy retains the same token canary.
        continuation = nil
        return try await concurrencyRuntime.awaitContinuation(record)
    }

    func runtimeCheckedContinuationMember(
        _ name: String,
        on payload: Any
    ) -> RuntimeValue? {
        guard let continuation = payload as? RuntimeCheckedContinuation,
              name == "resume" else { return nil }
        return .hostFunction(HostFunction(name: name) { arguments, _ in
            // Swift exposes this convenience only when the success value is
            // Void; compiler preflight owns that static member constraint.
            if arguments.arguments.isEmpty {
                try continuation.resume(returning: .void)
                return .void
            }
            guard arguments.arguments.count == 1 else {
                throw RuntimeError(message:
                    "CheckedContinuation.resume accepts zero or one value")
            }
            if let value = arguments.labeled("returning") {
                try continuation.resume(returning: value)
                return .void
            }
            if let value = arguments.labeled("throwing") {
                try continuation.resume(throwing: value)
                return .void
            }
            if let result = arguments.labeled("with") {
                try continuation.resume(with: result)
                return .void
            }
            throw RuntimeError(message:
                "CheckedContinuation.resume currently requires returning:, "
                    + "throwing:, or with:")
        })
    }
}
