/// The source token is a small capability over a runtime-owned continuation
/// record. It deliberately retains only the record identity after completion;
/// an escaped token cannot keep its task, session, or interpreter alive.
final class RuntimeCheckedContinuation: RuntimeConcurrencyHostValue {
    weak var runtime: CooperativeConcurrencyRuntime?
    let id: RuntimeContinuationID
    let allowsThrowingResume: Bool
    private var didResume = false

    init(
        runtime: CooperativeConcurrencyRuntime,
        id: RuntimeContinuationID,
        allowsThrowingResume: Bool
    ) {
        self.runtime = runtime
        self.id = id
        self.allowsThrowingResume = allowsThrowingResume
    }

    var sourceTypeName: String { "CheckedContinuation" }
    var sourceProtocolNames: [String] { [] }

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
        guard let isolation = arguments.labeled("isolation") else {
            throw RuntimeError(message:
                "\(api) currently requires an explicit "
                    + "isolation argument")
        }
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
            guard executor == .mainActor else {
                throw RuntimeError(message:
                    "\(api) currently supports only nil "
                        + "or MainActor isolation")
            }
            bodyExecutor = executor
        }
        if let function = arguments.labeled("function"),
           function.stringValue == nil {
            throw RuntimeError(message:
                "\(api)(function:) requires a String")
        }
        guard let body = arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "\(api) needs a body closure")
        }

        let record = try concurrencyRuntime.createContinuation(
            ownerTaskID: task.id,
            requiredExecutor: evaluationTaskContext.currentExecutor)
        let continuation = RuntimeCheckedContinuation(
            runtime: concurrencyRuntime,
            id: record.id,
            allowsThrowingResume: allowsThrowingResume)
        do {
            _ = try callWithArguments(
                body,
                args: CallArguments(arguments: [
                    .init(label: nil, value: .native(continuation))
                ]),
                node: nil,
                contextualExecutor: bodyExecutor)
        } catch {
            concurrencyRuntime.discardContinuation(record)
            throw error
        }
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
