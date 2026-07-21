enum RuntimeTaskGroupKind: CaseIterable, Equatable, Sendable {
    case nonthrowing
    case throwing
    case discarding
    case throwingDiscarding

    init?(functionIntrinsic: RuntimeConcurrencyFunctionIntrinsic) {
        switch functionIntrinsic {
        case .withTaskGroup: self = .nonthrowing
        case .withThrowingTaskGroup: self = .throwing
        case .withDiscardingTaskGroup: self = .discarding
        case .withThrowingDiscardingTaskGroup: self = .throwingDiscarding
        case .unstructuredTask, .detachedTask, .extractIsolation,
             .withCheckedContinuation,
             .withCheckedThrowingContinuation,
             .unsafeContinuation,
             .withTaskCancellationHandler,
             .withTaskPriorityEscalationHandler,
             .withTaskExecutorPreference,
             .withCurrentTaskCapability:
            return nil
        }
    }

    var functionIntrinsic: RuntimeConcurrencyFunctionIntrinsic {
        switch self {
        case .nonthrowing: .withTaskGroup
        case .throwing: .withThrowingTaskGroup
        case .discarding: .withDiscardingTaskGroup
        case .throwingDiscarding: .withThrowingDiscardingTaskGroup
        }
    }

    var sourceFunctionName: String {
        functionIntrinsic.rawValue
    }

    var sourceTypeName: String {
        switch self {
        case .nonthrowing: "TaskGroup"
        case .throwing: "ThrowingTaskGroup"
        case .discarding: "DiscardingTaskGroup"
        case .throwingDiscarding: "ThrowingDiscardingTaskGroup"
        }
    }

    var isThrowing: Bool {
        switch self {
        case .nonthrowing, .discarding: false
        case .throwing, .throwingDiscarding: true
        }
    }

    var discardsResults: Bool {
        switch self {
        case .nonthrowing, .throwing: false
        case .discarding, .throwingDiscarding: true
        }
    }

    var requiresChildResultType: Bool { !discardsResults }
}

/// Source-facing capability for one active task-group scope.
/// Swift prevents this value from escaping through `inout`; runtime checks
/// retain the same lifetime boundary for dynamically invoked source.
@MainActor
final class RuntimeTaskGroup {
    let record: RuntimeTaskGroupRecord
    private(set) var childHandles: [RuntimeTaskHandle] = []
    private(set) var isClosed = false

    init(record: RuntimeTaskGroupRecord) {
        self.record = record
    }

    var id: RuntimeTaskGroupID { record.id }
    var ownerTaskID: RuntimeTaskID { record.ownerTaskID }
    var kind: RuntimeTaskGroupKind { record.kind }
    var hasCancelAllRequest: Bool {
        record.hasCancelAllRequest
    }
    var hasOwnerCancellationRequest: Bool {
        record.hasOwnerCancellationRequest
    }
    var hasChildFailureCancellationRequest: Bool {
        record.hasChildFailureCancellationRequest
    }
    var isCancellationRequested: Bool {
        record.isCancellationRequested
    }

    var newChildCancellationSources: [RuntimeCancellationSource] {
        var sources: [RuntimeCancellationSource] = []
        if hasOwnerCancellationRequest {
            sources.append(.structuredParent)
        }
        if hasCancelAllRequest {
            sources.append(.taskGroupCancelAll)
        }
        if hasChildFailureCancellationRequest {
            sources.append(.taskGroupChildFailure)
        }
        return sources
    }

    func requireActive(ownerTaskID: RuntimeTaskID?) throws {
        guard !isClosed else {
            throw RuntimeError(message: "task group escaped its source scope")
        }
        guard ownerTaskID == record.ownerTaskID else {
            throw RuntimeError(message:
                "task group can only be used by its owning task")
        }
    }

    func append(_ handle: RuntimeTaskHandle) {
        precondition(!isClosed, "cannot add a child to a closed task group")
        childHandles.append(handle)
    }

    func removePending(_ handle: RuntimeTaskHandle) {
        precondition(
            childHandles.last === handle,
            "task-group launch rollback must remove its newest child")
        childHandles.removeLast()
    }

    func requestCancelAll() {
        precondition(!isClosed, "cannot cancel a closed task group")
        record.hasCancelAllRequest = true
    }

    func close() {
        precondition(!isClosed, "task group closed twice")
        isClosed = true
        childHandles.removeAll(keepingCapacity: false)
    }
}

/// Source-facing iterator capability returned by `TaskGroup.makeAsyncIterator`.
/// It intentionally shares the owning group's completion queue while retaining
/// a distinct member surface; returning the group itself would incorrectly
/// expose child creation and cancellation through an iterator value.
@MainActor
final class RuntimeTaskGroupIterator: HostValueSemantic {
    let group: RuntimeTaskGroup
    private(set) var isFinished: Bool

    init(group: RuntimeTaskGroup, isFinished: Bool = false) {
        self.group = group
        self.isFinished = isFinished
    }

    func markFinished() {
        isFinished = true
    }

    func copiedHostValue() -> Any {
        RuntimeTaskGroupIterator(group: group, isFinished: isFinished)
    }
}
