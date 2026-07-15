/// The observable lifecycle of an interpreted `Task`.
///
/// The handle is a core runtime value rather than a SwiftUI stub: cancellation
/// and completion semantics must be identical for every host registry.
public enum RuntimeTaskOutcome {
    case success(RuntimeValue, successType: String?)
    case failure(RuntimeValue, failureType: String?)
    case cancelled
}

/// Source-visible `Result` produced by `await Task.result`.
///
/// The value keeps interpreted payloads intact so enum-pattern matching and
/// `get()` can rethrow an app-defined error rather than reducing it to text.
public final class RuntimeResultValue: CaseShaped, CustomStringConvertible {
    public enum Outcome {
        case success(RuntimeValue, type: String?)
        case failure(RuntimeValue, type: String?)
    }

    public let outcome: Outcome

    public init(taskOutcome: RuntimeTaskOutcome) {
        switch taskOutcome {
        case .success(let value, let type):
            outcome = .success(value, type: type)
        case .failure(let value, let type):
            outcome = .failure(value, type: type)
        case .cancelled:
            outcome = .failure(
                .native(CancellationError()), type: "CancellationError")
        }
    }

    public var caseName: String {
        switch outcome {
        case .success: "success"
        case .failure: "failure"
        }
    }

    public var casePayloads: [RuntimeValue] {
        switch outcome {
        case .success(let value, _), .failure(let value, _): [value]
        }
    }

    public var description: String {
        "Result.\(caseName)(\(casePayloads[0].stringified))"
    }
}

public final class RuntimeTaskHandle {
    public typealias State = RuntimeTaskState

    /// Value-only state retained after the active registry and native driver
    /// are released. Runtime values survive only through the logical outcome,
    /// which is exactly what later `value` and `result` reads require.
    private struct ReleasedState {
        let id: RuntimeTaskID
        let sessionID: RuntimeSessionID
        let kind: RuntimeTaskKind
        let parent: RuntimeTaskID?
        let basePriority: RuntimeTaskPriority
        let effectivePriority: RuntimeTaskPriority
        let state: RuntimeTaskState
        let suspension: RuntimeSuspension?
        let suspensionHistory: [RuntimeSuspension]
        let outcome: RuntimeTaskOutcome?
        let failureDescription: String?
        var cancellation: RuntimeCancellationState
        let waiterCount: Int
        let waitingOnTaskIDs: Set<RuntimeTaskID>
        let priorityEscalationHistory: [
            RuntimeTaskID: RuntimeTaskPriority
        ]
        let spawnedTaskIDs: Set<RuntimeTaskID>
        let structuredChildIDs: Set<RuntimeTaskID>
        let taskLocalCount: Int
        let cancellationHandlerCount: Int
        let cancellationHandlerInvocationCount: Int
        var nextCancellationSequence: UInt64

        init(
            record: RuntimeTaskRecord,
            nextCancellationSequence: UInt64
        ) {
            id = record.id
            sessionID = record.sessionID
            kind = record.kind
            parent = record.parent
            basePriority = record.basePriority
            effectivePriority = record.effectivePriority
            state = record.state
            suspension = record.suspension
            suspensionHistory = record.suspensionHistory
            outcome = record.outcome
            failureDescription = record.failureDescription
            cancellation = record.cancellation
            waiterCount = record.waiters.count
            waitingOnTaskIDs = record.waitingOnTasks
            priorityEscalationHistory = record.priorityEscalationHistory
            spawnedTaskIDs = record.spawnedTasks
            structuredChildIDs = record.structuredChildren
            taskLocalCount = record.taskLocals.count
            cancellationHandlerCount = record.activeCancellationHandlerCount
            cancellationHandlerInvocationCount =
                record.cancellationHandlerInvocationCount
            self.nextCancellationSequence = nextCancellationSequence
        }

        mutating func requestCancellation(
            from source: RuntimeCancellationSource
        ) {
            cancellation.request(
                from: source, sequence: nextCancellationSequence)
            nextCancellationSequence &+= 1
        }
    }

    private var runtime: CooperativeConcurrencyRuntime?
    private var activeRecord: RuntimeTaskRecord?
    private var releasedState: ReleasedState?

    /// Tests and runtime diagnostics may inspect an active record, but a
    /// released source handle deliberately has no record ownership edge.
    var record: RuntimeTaskRecord {
        guard let activeRecord else {
            preconditionFailure("runtime task \(id) has already been released")
        }
        return activeRecord
    }

    private var released: ReleasedState {
        guard let releasedState else {
            preconditionFailure("runtime task handle has no active or released state")
        }
        return releasedState
    }

    public var id: RuntimeTaskID { activeRecord?.id ?? released.id }
    public var sessionID: RuntimeSessionID {
        activeRecord?.sessionID ?? released.sessionID
    }
    public var kind: RuntimeTaskKind { activeRecord?.kind ?? released.kind }
    public var parent: RuntimeTaskID? {
        if let activeRecord { return activeRecord.parent }
        return released.parent
    }
    public var basePriority: RuntimeTaskPriority {
        activeRecord?.basePriority ?? released.basePriority
    }
    public var effectivePriority: RuntimeTaskPriority {
        activeRecord?.effectivePriority ?? released.effectivePriority
    }
    public var state: State { activeRecord?.state ?? released.state }
    public var suspension: RuntimeSuspension? {
        if let activeRecord { return activeRecord.suspension }
        return released.suspension
    }
    public var suspensionHistory: [RuntimeSuspension] {
        activeRecord?.suspensionHistory ?? released.suspensionHistory
    }
    public var outcome: RuntimeTaskOutcome? {
        if let activeRecord { return activeRecord.outcome }
        return released.outcome
    }
    public var failureDescription: String? {
        if let activeRecord { return activeRecord.failureDescription }
        return released.failureDescription
    }
    public var cancellation: RuntimeCancellationState {
        activeRecord?.cancellation ?? released.cancellation
    }
    var waiterCount: Int {
        activeRecord?.waiters.count ?? released.waiterCount
    }
    var waitingOnTaskIDs: Set<RuntimeTaskID> {
        activeRecord?.waitingOnTasks ?? released.waitingOnTaskIDs
    }
    var priorityEscalationHistory: [
        RuntimeTaskID: RuntimeTaskPriority
    ] {
        activeRecord?.priorityEscalationHistory
            ?? released.priorityEscalationHistory
    }
    var spawnedTaskIDs: Set<RuntimeTaskID> {
        activeRecord?.spawnedTasks ?? released.spawnedTaskIDs
    }
    var structuredChildIDs: Set<RuntimeTaskID> {
        activeRecord?.structuredChildren ?? released.structuredChildIDs
    }
    var taskLocalCount: Int {
        activeRecord?.taskLocals.count ?? released.taskLocalCount
    }
    var cancellationHandlerCount: Int {
        activeRecord?.activeCancellationHandlerCount
            ?? released.cancellationHandlerCount
    }
    var cancellationHandlerInvocationCount: Int {
        activeRecord?.cancellationHandlerInvocationCount
            ?? released.cancellationHandlerInvocationCount
    }

    public convenience init() {
        let runtime = CooperativeConcurrencyRuntime()
        let record = runtime.createTask(
            sessionID: runtime.createSession(),
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .cooperativeDefault,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        self.init(runtime: runtime, record: record)
    }

    init(
        runtime: CooperativeConcurrencyRuntime,
        record: RuntimeTaskRecord
    ) {
        self.runtime = runtime
        activeRecord = record
        releasedState = nil
        precondition(
            record.sourceHandle == nil,
            "runtime task \(record.id) already has a source handle")
        record.sourceHandle = self
    }

    public var result: RuntimeValue? {
        guard case .success(let value, _) = outcome else { return nil }
        return value
    }

    public var resultValue: RuntimeResultValue? {
        outcome.map(RuntimeResultValue.init(taskOutcome:))
    }

    public var isCancelled: Bool { cancellation.isRequested }
    public var isCompleted: Bool { state.isCompleted }

    public func cancel() {
        cancel(source: .taskHandle)
    }

    func cancel(source: RuntimeCancellationSource) {
        if let runtime, let activeRecord {
            runtime.requestCancellation(activeRecord, source: source)
            return
        }
        guard var releasedState else {
            preconditionFailure("runtime task handle has no state")
        }
        releasedState.requestCancellation(from: source)
        self.releasedState = releasedState
    }

    func completeCancellation() {
        guard let runtime, let activeRecord else {
            preconditionFailure("cannot complete a released runtime task")
        }
        runtime.completeCancellation(activeRecord)
    }

    func attach(_ task: Task<Void, Never>) {
        guard let runtime, let activeRecord else {
            preconditionFailure("cannot attach a driver to a released runtime task")
        }
        runtime.attach(task, to: activeRecord)
    }

    @discardableResult
    func begin() -> Bool {
        guard let runtime, let activeRecord else {
            preconditionFailure("cannot begin a released runtime task")
        }
        return runtime.begin(activeRecord)
    }

    func succeed(with value: RuntimeValue) {
        guard let runtime, let activeRecord else {
            preconditionFailure("cannot complete a released runtime task")
        }
        runtime.succeed(activeRecord, with: value)
    }

    func fail(with error: Error) {
        guard let runtime, let activeRecord else {
            preconditionFailure("cannot complete a released runtime task")
        }
        runtime.fail(activeRecord, with: error)
    }

    func wait() async {
        guard let task = activeRecord?.nativeDriver?.task else { return }
        await task.value
    }

    func waitForOutcome(
        waiter: RuntimeTaskID? = nil
    ) async -> RuntimeTaskOutcome {
        guard let runtime, let record = activeRecord else {
            return outcome ?? .failure(
                .native("task completed without an outcome"),
                failureType: "RuntimeTaskInvariant")
        }
        let suspension: RuntimeSuspension?
        if let waiter, !record.state.isCompleted {
            runtime.beginWaiting(waiter, on: record)
            let reason = RuntimeSuspension.awaitingTask(record.id)
            runtime.suspend(waiter, for: reason)
            suspension = reason
        } else {
            suspension = nil
        }
        defer {
            if let waiter, let suspension {
                runtime.resume(waiter, from: suspension)
                runtime.endWaiting(waiter, on: record)
            }
        }
        if let task = record.nativeDriver?.task {
            await task.value
        }
        return record.outcome ?? .failure(
            .native("task completed without an outcome"),
            failureType: "RuntimeTaskInvariant")
    }

    /// Atomically sever active execution ownership while retaining the
    /// source-observable terminal state needed by an escaped task value.
    func detachFromRuntime(
        _ record: RuntimeTaskRecord,
        nextCancellationSequence: UInt64
    ) {
        precondition(
            activeRecord === record,
            "runtime attempted to release the wrong source handle")
        releasedState = ReleasedState(
            record: record,
            nextCancellationSequence: nextCancellationSequence)
        activeRecord = nil
        runtime = nil
    }
}
