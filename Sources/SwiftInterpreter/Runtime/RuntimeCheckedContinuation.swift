/// The source token is a small capability over a runtime-owned continuation
/// record. It deliberately retains only the record identity after completion;
/// an escaped token cannot keep its task, session, or interpreter alive.
final class RuntimeCheckedContinuation: RuntimeConcurrencyHostValue {
    weak var runtime: CooperativeConcurrencyRuntime?
    let id: RuntimeContinuationID
    private var didResume = false

    init(
        runtime: CooperativeConcurrencyRuntime,
        id: RuntimeContinuationID
    ) {
        self.runtime = runtime
        self.id = id
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
}

enum RuntimeContinuationState {
    case pending
    case resumed(RuntimeValue)
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
            .withCheckedContinuation.rawValue
    ) -> HostFunction {
        HostFunction(
            name: name,
            tracksHostOperation: false,
            asyncInvoke: { [weak self] arguments, _ in
                guard let self else {
                    throw RuntimeError(message:
                        "interpreter was released during checked continuation")
                }
                return try await withSourceCheckedContinuation(arguments)
            })
    }

    private func withSourceCheckedContinuation(
        _ arguments: CallArguments
    ) async throws -> RuntimeValue {
        let task = try requireCanonicalActiveRuntimeTask(
            for: "withCheckedContinuation")
        guard let isolation = arguments.labeled("isolation"),
              isolation.isNil else {
            throw RuntimeError(message:
                "withCheckedContinuation currently requires explicit "
                    + "isolation: nil")
        }
        if let function = arguments.labeled("function"),
           function.stringValue == nil {
            throw RuntimeError(message:
                "withCheckedContinuation(function:) requires a String")
        }
        guard let body = arguments.firstUnlabeledClosure else {
            throw RuntimeError(message:
                "withCheckedContinuation needs a body closure")
        }

        let record = try concurrencyRuntime.createContinuation(
            ownerTaskID: task.id,
            requiredExecutor: evaluationTaskContext.currentExecutor)
        let continuation = RuntimeCheckedContinuation(
            runtime: concurrencyRuntime,
            id: record.id)
        do {
            _ = try callWithArguments(
                body,
                args: CallArguments(arguments: [
                    .init(label: nil, value: .native(continuation))
                ]),
                node: nil)
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
            guard arguments.arguments.count == 1,
                  let value = arguments.labeled("returning") else {
                throw RuntimeError(message:
                    "CheckedContinuation.resume currently requires "
                        + "returning: value")
            }
            try continuation.resume(returning: value)
            return .void
        })
    }
}
