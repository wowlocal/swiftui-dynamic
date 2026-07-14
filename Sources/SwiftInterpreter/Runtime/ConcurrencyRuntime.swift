import Foundation

/// Host boundary policy for tasks owned by one interpreter run. This does not
/// change the source-level relationship of an unstructured or detached task.
public enum SessionCompletionPolicy: Sendable {
    case topLevel
    case drainOwnedTasks
    case cancelRemainingTasks
}

public struct RuntimeSessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "session-\(rawValue)" }
}

public struct RuntimeTaskID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "task-\(rawValue)" }
}

public struct RuntimeStructuredScopeID: Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "structured-scope-\(rawValue)" }
}

public struct RuntimeTaskGroupID: Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "task-group-\(rawValue)" }
}

public struct HostOperationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "host-operation-\(rawValue)" }
}

struct RuntimeCancellationHandlerID: Hashable, Sendable {
    let rawValue: UInt64
}

/// Logical source-task priority. The native value drives today's cooperative
/// task, while keeping it on the runtime record/context gives later schedulers
/// and priority escalation one stable source of truth.
public struct RuntimeTaskPriority: Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ native: TaskPriority) {
        rawValue = native.rawValue
    }

    public static let high = Self(TaskPriority.high)
    public static let medium = Self(TaskPriority.medium)
    public static let low = Self(TaskPriority.low)
    public static let background = Self(TaskPriority.background)

    var nativePriority: TaskPriority { TaskPriority(rawValue: rawValue) }

    public static func < (
        lhs: RuntimeTaskPriority, rhs: RuntimeTaskPriority
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "TaskPriority(rawValue: \(rawValue))" }

    static func sourceValue(_ value: RuntimeValue?) throws -> Self? {
        guard let value, !value.isNil else { return nil }
        if case .host(let payload) = value,
           let priority = payload as? RuntimeTaskPriority {
            return priority
        }
        let name: String?
        switch value {
        case .implicitMember(let member):
            name = member
        case .host(let call as ImplicitMemberCall):
            name = call.name
        default:
            name = nil
        }
        switch name {
        case "high", "userInitiated": return .high
        case "medium": return .medium
        case "low", "utility": return .low
        case "background": return .background
        default:
            throw RuntimeError(message:
                "Task priority must be high, medium, low, utility, or background")
        }
    }
}

public enum RuntimeTaskKind: String, Sendable {
    case root
    case unstructured
    case detached
    case asyncLet
    case groupChild
    case hostCallback
    case swiftUITask
}

extension RuntimeTaskKind {
    var isStructuredChild: Bool {
        switch self {
        case .asyncLet, .groupChild:
            true
        case .root, .unstructured, .detached, .hostCallback, .swiftUITask:
            false
        }
    }
}

public enum RuntimeTaskState: String, Sendable {
    case pending
    case running
    case waiting
    case succeeded
    case cancelled
    case failed
}

public enum RuntimeSuspension: Hashable, Sendable, CustomStringConvertible {
    case awaitingTask(RuntimeTaskID)
    case awaitingHost(HostOperationID)
    case waitingForGroup(RuntimeTaskGroupID)
    case yielding
    case sleeping(until: RuntimeInstant)

    public var description: String {
        switch self {
        case .awaitingTask(let taskID): "awaitingTask(\(taskID))"
        case .awaitingHost(let operationID): "awaitingHost(\(operationID))"
        case .waitingForGroup(let groupID): "waitingForGroup(\(groupID))"
        case .yielding: "yielding"
        case .sleeping(let deadline): "sleeping(until: \(deadline))"
        }
    }
}

public enum RuntimeCancellationSource: Hashable, Sendable {
    case taskHandle
    case sessionPolicy
    case hostTask
    case inherited
    case structuredParent
    case structuredScopeExit
}

public struct RuntimeCancellationState: Sendable {
    public private(set) var sources: Set<RuntimeCancellationSource> = []
    public private(set) var requestSequence: UInt64?
    public private(set) var observationSequence: UInt64?

    public var isRequested: Bool { !sources.isEmpty }
    public var isObserved: Bool { observationSequence != nil }

    mutating func request(
        from source: RuntimeCancellationSource,
        sequence: UInt64
    ) {
        sources.insert(source)
        if requestSequence == nil { requestSequence = sequence }
    }

    mutating func observe(sequence: UInt64) {
        if observationSequence == nil { observationSequence = sequence }
    }
}

/// Infrastructure teardown must not be catchable as an ordinary source
/// `CancellationError`.
struct InterpreterSessionAbort: Error {}

/// One dynamically-scoped source cancellation handler. The runtime invokes
/// the callback synchronously from the task that requests cancellation, just
/// as native `Task.cancel()` does; the closure's lexical captures remain its
/// own, while task-local dynamic context belongs to the cancelling task.
private final class RuntimeCancellationHandlerRegistration {
    let id: RuntimeCancellationHandlerID
    let invoke: @MainActor () throws -> Void
    var wasInvoked = false

    init(
        id: RuntimeCancellationHandlerID,
        invoke: @escaping @MainActor () throws -> Void
    ) {
        self.id = id
        self.invoke = invoke
    }
}

/// Mutable lifecycle record owned by the cooperative concurrency runtime.
/// The source-level handle retains this record after session bookkeeping has
/// released it, so completed task values remain readable without leaking them
/// from the runtime's active registry.
final class RuntimeTaskRecord {
    let id: RuntimeTaskID
    let sessionID: RuntimeSessionID
    let kind: RuntimeTaskKind
    let parent: RuntimeTaskID?
    let basePriority: RuntimeTaskPriority
    var effectivePriority: RuntimeTaskPriority
    let taskLocals: RuntimeTaskLocalStorage
    var state: RuntimeTaskState = .pending
    var suspension: RuntimeSuspension?
    var suspensionHistory: [RuntimeSuspension] = []
    var outcome: RuntimeTaskOutcome?
    var failureDescription: String?
    var cancellation = RuntimeCancellationState()
    fileprivate var cancellationHandlers: [
        RuntimeCancellationHandlerRegistration
    ] = []
    var activeCancellationHandlerCount: Int {
        cancellationHandlers.count
    }
    var cancellationHandlerInvocationCount = 0
    var cancellationHandlerFailure: Error?
    var waiters: Set<RuntimeTaskID> = []
    var waitingOnTasks: Set<RuntimeTaskID> = []
    var priorityEscalationHistory: [
        RuntimeTaskID: RuntimeTaskPriority
    ] = [:]
    var spawnedTasks: Set<RuntimeTaskID> = []
    var structuredChildren: Set<RuntimeTaskID> = []
    var structuredScopes: Set<RuntimeStructuredScopeID> = []
    var nativeTask: Task<Void, Never>?
    var evaluationContext: EvaluationTaskContext?

    init(
        id: RuntimeTaskID,
        sessionID: RuntimeSessionID,
        kind: RuntimeTaskKind,
        parent: RuntimeTaskID?,
        priority: RuntimeTaskPriority,
        taskLocals: RuntimeTaskLocalStorage
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.parent = parent
        basePriority = priority
        effectivePriority = priority
        self.taskLocals = taskLocals
    }
}

/// One lexical structured-concurrency scope owned by a source task. Child
/// task records remain in the task graph, while this record identifies the
/// subset whose lifetime must be closed before the lexical block can exit.
enum RuntimeStructuredScopeKind {
    case asyncLet
    case taskGroup
}

final class RuntimeStructuredScopeRecord {
    let id: RuntimeStructuredScopeID
    let ownerTaskID: RuntimeTaskID
    let kind: RuntimeStructuredScopeKind
    var childTaskIDs: Set<RuntimeTaskID> = []

    init(
        id: RuntimeStructuredScopeID,
        ownerTaskID: RuntimeTaskID,
        kind: RuntimeStructuredScopeKind
    ) {
        self.id = id
        self.ownerTaskID = ownerTaskID
        self.kind = kind
    }
}

/// Runtime identity and structured ownership for one nonthrowing source task
/// group. Source-facing mutation stays on `RuntimeTaskGroup`; the scheduler
/// record keeps only task IDs and the shared lexical scope edge.
final class RuntimeTaskGroupRecord {
    let id: RuntimeTaskGroupID
    let ownerTaskID: RuntimeTaskID
    let structuredScope: RuntimeStructuredScopeRecord
    var childTaskIDs: [RuntimeTaskID] = []

    init(
        id: RuntimeTaskGroupID,
        ownerTaskID: RuntimeTaskID,
        structuredScope: RuntimeStructuredScopeRecord
    ) {
        self.id = id
        self.ownerTaskID = ownerTaskID
        self.structuredScope = structuredScope
    }
}

final class CooperativeConcurrencyRuntime {
    let clock: any RuntimeClock
    private var nextSessionID: UInt64 = 1
    private var nextTaskID: UInt64 = 1
    private var nextStructuredScopeID: UInt64 = 1
    private var nextTaskGroupID: UInt64 = 1
    private var nextHostOperationID: UInt64 = 1
    private var nextCancellationHandlerID: UInt64 = 1
    private var nextEventSequence: UInt64 = 1
    private(set) var records: [RuntimeTaskID: RuntimeTaskRecord] = [:]
    private(set) var structuredScopes: [
        RuntimeStructuredScopeID: RuntimeStructuredScopeRecord
    ] = [:]
    private(set) var taskGroups: [
        RuntimeTaskGroupID: RuntimeTaskGroupRecord
    ] = [:]
    private(set) var hostOperations: [HostOperationID: RuntimeTaskID] = [:]

    init(clock: any RuntimeClock = ContinuousRuntimeClock()) {
        self.clock = clock
    }

    func createSession() -> RuntimeSessionID {
        let id = RuntimeSessionID(rawValue: nextSessionID)
        nextSessionID += 1
        return id
    }

    func createTask(
        sessionID: RuntimeSessionID,
        kind: RuntimeTaskKind,
        parent: RuntimeTaskID?,
        priority: RuntimeTaskPriority,
        taskLocals: RuntimeTaskLocalStorage
    ) -> RuntimeTaskRecord {
        let id = RuntimeTaskID(rawValue: nextTaskID)
        nextTaskID += 1
        let record = RuntimeTaskRecord(
            id: id, sessionID: sessionID, kind: kind, parent: parent,
            priority: priority, taskLocals: taskLocals)
        records[id] = record
        if let parent, let parentRecord = records[parent] {
            // Creation/inheritance and structured ownership are deliberately
            // separate edges. `Task {}` has a creator but is not a structured
            // child and must not receive cancellation through this relation.
            parentRecord.spawnedTasks.insert(id)
            if kind.isStructuredChild {
                parentRecord.structuredChildren.insert(id)
            }
        }
        return record
    }

    func createStructuredScope(
        ownerTaskID: RuntimeTaskID,
        kind: RuntimeStructuredScopeKind = .asyncLet
    ) -> RuntimeStructuredScopeRecord {
        guard let owner = records[ownerTaskID], !owner.state.isCompleted else {
            preconditionFailure(
                "cannot create a structured scope for inactive task \(ownerTaskID)")
        }
        let id = RuntimeStructuredScopeID(rawValue: nextStructuredScopeID)
        nextStructuredScopeID += 1
        let scope = RuntimeStructuredScopeRecord(
            id: id, ownerTaskID: ownerTaskID, kind: kind)
        precondition(
            structuredScopes.updateValue(scope, forKey: id) == nil,
            "duplicate structured scope ID \(id)")
        owner.structuredScopes.insert(id)
        return scope
    }

    func createTaskGroup(
        ownerTaskID: RuntimeTaskID
    ) -> RuntimeTaskGroupRecord {
        let scope = createStructuredScope(
            ownerTaskID: ownerTaskID, kind: .taskGroup)
        let id = RuntimeTaskGroupID(rawValue: nextTaskGroupID)
        nextTaskGroupID += 1
        let group = RuntimeTaskGroupRecord(
            id: id, ownerTaskID: ownerTaskID, structuredScope: scope)
        precondition(
            taskGroups.updateValue(group, forKey: id) == nil,
            "duplicate task group ID \(id)")
        return group
    }

    func addStructuredChild(
        _ childID: RuntimeTaskID,
        to scope: RuntimeStructuredScopeRecord
    ) {
        guard structuredScopes[scope.id] === scope,
              let child = records[childID],
              child.parent == scope.ownerTaskID,
              child.kind.isStructuredChild else {
            preconditionFailure(
                "task \(childID) is not a child of \(scope.id)")
        }
        scope.childTaskIDs.insert(childID)
    }

    func addGroupChild(
        _ childID: RuntimeTaskID,
        to group: RuntimeTaskGroupRecord
    ) {
        guard taskGroups[group.id] === group else {
            preconditionFailure("cannot add a child to inactive \(group.id)")
        }
        addStructuredChild(childID, to: group.structuredScope)
        precondition(
            !group.childTaskIDs.contains(childID),
            "duplicate child \(childID) in \(group.id)")
        group.childTaskIDs.append(childID)
    }

    func beginWaitingForTaskGroup(
        _ waiterID: RuntimeTaskID,
        on group: RuntimeTaskGroupRecord
    ) -> RuntimeSuspension? {
        guard taskGroups[group.id] === group,
              group.ownerTaskID == waiterID else {
            preconditionFailure(
                "task \(waiterID) cannot wait on inactive \(group.id)")
        }
        let incomplete = group.childTaskIDs.compactMap { childID -> RuntimeTaskRecord? in
            guard let child = records[childID], !child.state.isCompleted else {
                return nil
            }
            return child
        }
        guard !incomplete.isEmpty else { return nil }
        for child in incomplete {
            beginWaiting(waiterID, on: child)
        }
        let suspension = RuntimeSuspension.waitingForGroup(group.id)
        suspend(waiterID, for: suspension)
        return suspension
    }

    func endWaitingForTaskGroup(
        _ waiterID: RuntimeTaskID,
        on group: RuntimeTaskGroupRecord,
        from suspension: RuntimeSuspension?
    ) {
        guard let suspension else { return }
        resume(waiterID, from: suspension)
        for childID in group.childTaskIDs {
            guard let child = records[childID] else { continue }
            endWaiting(waiterID, on: child)
        }
    }

    func closeTaskGroup(_ group: RuntimeTaskGroupRecord) {
        guard taskGroups[group.id] === group else {
            preconditionFailure("cannot close inactive \(group.id)")
        }
        precondition(
            group.childTaskIDs.allSatisfy {
                records[$0]?.state.isCompleted == true
            },
            "cannot close \(group.id) while a child is active")
        closeStructuredScope(group.structuredScope)
        taskGroups.removeValue(forKey: group.id)
    }

    func closeStructuredScope(_ scope: RuntimeStructuredScopeRecord) {
        guard structuredScopes[scope.id] === scope else {
            preconditionFailure("cannot close inactive scope \(scope.id)")
        }
        precondition(
            scope.childTaskIDs.allSatisfy {
                records[$0]?.state.isCompleted == true
            },
            "cannot close \(scope.id) while a child is active")
        records[scope.ownerTaskID]?.structuredScopes.remove(scope.id)
        structuredScopes.removeValue(forKey: scope.id)
    }

    func bind(
        _ context: EvaluationTaskContext, to record: RuntimeTaskRecord
    ) {
        context.priority = record.effectivePriority
        record.evaluationContext = context
    }

    /// Register one source task's suspension on another task and donate the
    /// waiter's effective priority. Escalation is monotonic for the lifetime
    /// of a task, matching Swift's task-priority model; ending the wait removes
    /// only the dependency edge, not an escalation already observed by the
    /// awaited task.
    func beginWaiting(
        _ waiterID: RuntimeTaskID, on awaited: RuntimeTaskRecord
    ) {
        guard let waiter = records[waiterID] else { return }
        awaited.waiters.insert(waiterID)
        waiter.waitingOnTasks.insert(awaited.id)
        guard !awaited.state.isCompleted else { return }

        var visited: Set<RuntimeTaskID> = [waiterID]
        donatePriority(
            waiter.effectivePriority,
            from: waiterID,
            to: awaited.id,
            visited: &visited)
    }

    func endWaiting(
        _ waiterID: RuntimeTaskID, on awaited: RuntimeTaskRecord
    ) {
        awaited.waiters.remove(waiterID)
        records[waiterID]?.waitingOnTasks.remove(awaited.id)
    }

    func attach(
        _ nativeTask: Task<Void, Never>, to record: RuntimeTaskRecord
    ) {
        record.nativeTask = nativeTask
        if record.cancellation.isRequested { nativeTask.cancel() }
    }

    @discardableResult
    func begin(_ record: RuntimeTaskRecord) -> Bool {
        guard record.state == .pending else { return false }
        record.state = .running
        return true
    }

    func succeed(_ record: RuntimeTaskRecord, with value: RuntimeValue) {
        guard record.state != .cancelled else { return }
        record.outcome = .success(
            value, successType: HostRuntimeTypeSystem.typeName(of: value))
        record.state = .succeeded
        record.suspension = nil
        record.evaluationContext = nil
    }

    func fail(_ record: RuntimeTaskRecord, with error: Error) {
        guard record.state != .cancelled else { return }
        record.failureDescription = String(describing: error)
        if let thrown = error as? InterpretedThrow {
            record.outcome = .failure(
                thrown.value,
                failureType: HostRuntimeTypeSystem.typeName(of: thrown.value))
        } else {
            record.outcome = .failure(
                .native(String(describing: error)),
                failureType: String(describing: type(of: error)))
        }
        record.state = .failed
        record.suspension = nil
        record.evaluationContext = nil
    }

    func requestCancellation(
        _ record: RuntimeTaskRecord,
        source: RuntimeCancellationSource
    ) {
        guard !record.state.isCompleted else { return }
        let wasAlreadyRequested = record.cancellation.isRequested
        let alreadyRequestedFromSource =
            record.cancellation.sources.contains(source)
        record.cancellation.request(
            from: source, sequence: takeEventSequence())
        record.nativeTask?.cancel()
        clock.cancelSleep(task: record.id)
        if !wasAlreadyRequested {
            invokeCancellationHandlers(on: record)
        }
        guard !alreadyRequestedFromSource else { return }
        for childID in record.structuredChildren {
            guard let child = records[childID] else { continue }
            requestCancellation(child, source: .structuredParent)
        }
    }

    func addCancellationHandler(
        to taskID: RuntimeTaskID,
        invoke: @escaping @MainActor () throws -> Void
    ) -> RuntimeCancellationHandlerID {
        guard let record = records[taskID], !record.state.isCompleted else {
            preconditionFailure(
                "cannot register a cancellation handler on inactive task \(taskID)")
        }
        let id = RuntimeCancellationHandlerID(
            rawValue: nextCancellationHandlerID)
        nextCancellationHandlerID += 1
        let registration = RuntimeCancellationHandlerRegistration(
            id: id, invoke: invoke)
        record.cancellationHandlers.append(registration)
        if record.cancellation.isRequested {
            invokeCancellationHandler(registration, on: record)
        }
        return id
    }

    func removeCancellationHandler(
        _ handlerID: RuntimeCancellationHandlerID,
        from taskID: RuntimeTaskID
    ) {
        guard let record = records[taskID] else { return }
        record.cancellationHandlers.removeAll { $0.id == handlerID }
    }

    func throwCancellationHandlerFailure(for taskID: RuntimeTaskID) throws {
        guard let failure = records[taskID]?.cancellationHandlerFailure else {
            return
        }
        throw failure
    }

    func completeCancellation(_ record: RuntimeTaskRecord) {
        guard !record.state.isCompleted else { return }
        record.cancellation.observe(sequence: takeEventSequence())
        record.outcome = .cancelled
        record.state = .cancelled
        record.suspension = nil
        record.evaluationContext = nil
    }

    func observeCancellation(
        _ id: RuntimeTaskID,
        inferredSource: RuntimeCancellationSource = .hostTask
    ) {
        guard let record = records[id] else { return }
        if !record.cancellation.isRequested {
            record.cancellation.request(
                from: inferredSource, sequence: takeEventSequence())
        }
        record.cancellation.observe(sequence: takeEventSequence())
    }

    func requiresSessionAbort(_ id: RuntimeTaskID) -> Bool {
        guard let record = records[id] else { return false }
        return record.kind == .root
            || record.cancellation.sources.contains(.sessionPolicy)
            || record.cancellation.sources.contains(.hostTask)
    }

    func release(_ id: RuntimeTaskID) {
        precondition(
            !hostOperations.values.contains(id),
            "cannot release runtime task \(id) with an active host operation")
        precondition(
            records[id]?.structuredScopes.isEmpty != false,
            "cannot release runtime task \(id) with an active structured scope")
        clock.cancelSleep(task: id)
        records[id]?.cancellationHandlers.removeAll(keepingCapacity: false)
        records.removeValue(forKey: id)
    }

    func suspend(_ id: RuntimeTaskID, for reason: RuntimeSuspension) {
        guard let record = records[id] else {
            preconditionFailure("cannot suspend unknown runtime task \(id)")
        }
        guard record.state == .running, record.suspension == nil else {
            preconditionFailure(
                "runtime task \(id) cannot suspend from \(record.state)")
        }
        record.state = .waiting
        record.suspension = reason
        record.suspensionHistory.append(reason)
    }

    func resume(_ id: RuntimeTaskID, from reason: RuntimeSuspension) {
        guard let record = records[id], !record.state.isCompleted else { return }
        guard record.state == .waiting, record.suspension == reason else {
            preconditionFailure(
                "runtime task \(id) resumed from an unregistered suspension")
        }
        record.suspension = nil
        record.state = .running
    }

    func beginHostOperation(for taskID: RuntimeTaskID) -> HostOperationID {
        let operationID = HostOperationID(rawValue: nextHostOperationID)
        nextHostOperationID += 1
        precondition(
            hostOperations.updateValue(taskID, forKey: operationID) == nil,
            "duplicate host operation ID \(operationID)")
        suspend(taskID, for: .awaitingHost(operationID))
        return operationID
    }

    func endHostOperation(
        _ operationID: HostOperationID, for taskID: RuntimeTaskID
    ) {
        precondition(
            hostOperations.removeValue(forKey: operationID) == taskID,
            "host operation \(operationID) has the wrong runtime task")
        resume(taskID, from: .awaitingHost(operationID))
    }

    func resumeHostOperationForCallback(
        _ operationID: HostOperationID, taskID: RuntimeTaskID
    ) {
        precondition(
            hostOperations[operationID] == taskID,
            "cannot re-enter inactive host operation \(operationID)")
        resume(taskID, from: .awaitingHost(operationID))
    }

    func suspendHostOperationAfterCallback(
        _ operationID: HostOperationID, taskID: RuntimeTaskID
    ) {
        precondition(
            hostOperations[operationID] == taskID,
            "cannot leave inactive host operation \(operationID)")
        suspend(taskID, for: .awaitingHost(operationID))
    }

    var activeRecordCount: Int { records.count }
    var activeHostOperationCount: Int { hostOperations.count }
    var activeStructuredScopeCount: Int { structuredScopes.count }
    var activeTaskGroupCount: Int { taskGroups.count }

    private func invokeCancellationHandlers(on record: RuntimeTaskRecord) {
        // The same-source Swift 6.3.3 probe establishes inner-to-outer
        // invocation for simultaneously active nested registrations. Taking
        // the reverse view also leaves one-shot state on each registration,
        // so repeated cancellation cannot invoke either handler again.
        for registration in record.cancellationHandlers.reversed() {
            invokeCancellationHandler(registration, on: record)
        }
    }

    private func invokeCancellationHandler(
        _ registration: RuntimeCancellationHandlerRegistration,
        on record: RuntimeTaskRecord
    ) {
        guard !registration.wasInvoked else { return }
        registration.wasInvoked = true
        record.cancellationHandlerInvocationCount += 1
        do {
            try registration.invoke()
        } catch {
            // Legal Swift handlers are nonthrowing. Preserve an interpreter
            // failure defensively and surface it from the cancelled task's
            // next safe point instead of silently swallowing it.
            if record.cancellationHandlerFailure == nil {
                record.cancellationHandlerFailure = error
            }
        }
    }

    private func donatePriority(
        _ priority: RuntimeTaskPriority,
        from donorID: RuntimeTaskID,
        to targetID: RuntimeTaskID,
        visited: inout Set<RuntimeTaskID>
    ) {
        guard visited.insert(targetID).inserted,
              let target = records[targetID],
              !target.state.isCompleted,
              target.effectivePriority < priority else { return }

        target.effectivePriority = priority
        target.priorityEscalationHistory[donorID] = priority
        target.evaluationContext?.priority = priority

        // If the escalated task is itself suspended on another task, Swift's
        // priority donation follows that dependency transitively.
        for dependencyID in target.waitingOnTasks {
            donatePriority(
                priority,
                from: target.id,
                to: dependencyID,
                visited: &visited)
        }
    }

    private func takeEventSequence() -> UInt64 {
        defer { nextEventSequence += 1 }
        return nextEventSequence
    }
}

extension RuntimeTaskState {
    var isCompleted: Bool {
        switch self {
        case .succeeded, .cancelled, .failed: true
        case .pending, .running, .waiting: false
        }
    }
}
