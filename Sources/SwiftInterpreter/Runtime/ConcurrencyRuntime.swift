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

public struct RuntimeActorID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "actor-\(rawValue)" }
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

public struct RuntimeAsyncStreamID: Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "async-stream-\(rawValue)" }
}

public struct RuntimeContinuationID: Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "continuation-\(rawValue)" }
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

struct RuntimePriorityEscalationHandlerID: Hashable, Sendable {
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

/// Converts the source-facing `String?` accepted by task creation APIs into
/// immutable task-record metadata. Optional payloads are unwrapped exactly
/// once; an empty string remains a real name and is never normalized to nil.
enum RuntimeTaskName {
    static func sourceValue(_ value: RuntimeValue?) throws -> String? {
        guard let value,
              let unwrapped = value.unwrappedOptionalOrSelf else {
            return nil
        }
        guard let name = unwrapped.stringValue else {
            throw RuntimeError(message: "task name must be a String?")
        }
        return name
    }
}

/// Task-executor preferences require an owned source executor implementation,
/// not merely a value-shaped argument. The cooperative runtime currently
/// supports only the native `nil` spelling, which requests no custom task
/// executor. Any non-nil value must fail closed instead of being silently
/// downgraded to the cooperative default executor.
enum RuntimeTaskExecutorPreference {
    static func requireSupportedNil(
        _ value: RuntimeValue?, api: String
    ) throws {
        guard value == nil || value?.isNil == true else {
            throw RuntimeError(message:
                "\(api)(executorPreference:) is not supported yet")
        }
    }
}

/// Resolves the actor inherited by an immediate-operation closure without
/// conflating it with task lineage. The current incremental runtime can make
/// the native synchronous-prefix guarantee only when caller and operation are
/// both MainActor-isolated; every other legal Swift shape remains fail-closed.
enum RuntimeImmediateOperationExecutor {
    static func supportedExecutor(
        operation: ClosureValue,
        context: EvalContext,
        api: String
    ) throws -> RuntimeExecutorKind {
        let operationExecutor: RuntimeExecutorKind?
        if let declaredExecutor = operation.executorPreference {
            operationExecutor = declaredExecutor
        } else if operation.functionDeclID != nil {
            // A source function without one of the executor annotations
            // modeled by ClosureValue may be nonisolated or belong to an
            // arbitrary actor. Do not reinterpret unknown isolation as
            // caller inheritance.
            operationExecutor = nil
        } else {
            // Closure expressions carry a statically derived lexical actor.
            // `nil` means unknown/nonisolated, not "use the dynamic caller".
            operationExecutor = operation.lexicalExecutor
        }
        guard context.sourceExecutor == .mainActor,
              let operationExecutor,
              operationExecutor == .mainActor else {
            throw RuntimeError(message:
                "\(api) currently requires a MainActor-inherited "
                    + "operation invoked from MainActor")
        }
        return operationExecutor
    }
}

/// Context inheritance, operation executor, and launch timing are independent
/// source semantics. In particular, `Task.immediateDetached` clears task
/// context while retaining both the inherited operation actor and immediate
/// start; none of these dimensions is inferred from another.
public enum RuntimeTaskContextInheritance: Sendable, Equatable {
    case inherited
    case detached
}

public enum RuntimeTaskStartPolicy: Sendable, Equatable {
    case enqueued
    case immediate
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

/// Logical source executor. During the cooperative phase every interpreter
/// instruction is still physically hosted by the native MainActor, but source
/// executor identity remains distinct and follows Swift's hop rules.
public enum RuntimeExecutorKind: Hashable, Sendable, CustomStringConvertible {
    case cooperativeDefault
    case mainActor
    case detached
    case actor(RuntimeActorID)

    public var isMainActor: Bool { self == .mainActor }

    public var actorID: RuntimeActorID? {
        guard case .actor(let id) = self else { return nil }
        return id
    }

    public var description: String {
        switch self {
        case .cooperativeDefault: "cooperativeDefault"
        case .mainActor: "mainActor"
        case .detached: "detached"
        case .actor(let id): "actor(\(id))"
        }
    }
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
    case waitingForStream(RuntimeAsyncStreamID)
    case waitingForContinuation(RuntimeContinuationID)
    case waitingForActor(RuntimeActorID)
    case yielding
    case sleeping(until: RuntimeInstant)

    public var description: String {
        switch self {
        case .awaitingTask(let taskID): "awaitingTask(\(taskID))"
        case .awaitingHost(let operationID): "awaitingHost(\(operationID))"
        case .waitingForGroup(let groupID): "waitingForGroup(\(groupID))"
        case .waitingForStream(let streamID):
            "waitingForStream(\(streamID))"
        case .waitingForContinuation(let continuationID):
            "waitingForContinuation(\(continuationID))"
        case .waitingForActor(let actorID): "waitingForActor(\(actorID))"
        case .yielding: "yielding"
        case .sleeping(let deadline): "sleeping(until: \(deadline))"
        }
    }
}

public enum RuntimeCancellationSource: Hashable, Sendable {
    case taskHandle
    case unsafeCurrentTask
    case sessionPolicy
    case hostTask
    case swiftUILifecycle
    case inherited
    case structuredParent
    case structuredScopeExit
    case taskGroupCancelAll
    case taskGroupChildFailure
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

/// One dynamically-scoped source priority-escalation handler. Priority
/// donation updates the target task before invoking every active registration;
/// adding a registration never replays an escalation that happened earlier.
private final class RuntimePriorityEscalationHandlerRegistration {
    let id: RuntimePriorityEscalationHandlerID
    let invoke: @MainActor (
        RuntimeTaskPriority, RuntimeTaskPriority
    ) throws -> Void

    init(
        id: RuntimePriorityEscalationHandlerID,
        invoke: @escaping @MainActor (
            RuntimeTaskPriority, RuntimeTaskPriority
        ) throws -> Void
    ) {
        self.id = id
        self.invoke = invoke
    }
}

/// Native execution resource retained only while a runtime task is active.
/// Keeping this as a reference object makes ownership independently testable:
/// a completed source handle must not retain either this driver or its task.
final class RuntimeNativeTaskDriver {
    let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }
}

/// Mutable lifecycle record owned by the cooperative concurrency runtime.
/// A source-level handle refers to this record only while execution is active;
/// `release(_:)` replaces that edge with a compact completion snapshot.
final class RuntimeTaskRecord {
    let id: RuntimeTaskID
    let entry: RuntimeEntry
    var sessionID: RuntimeSessionID { entry.id }
    let kind: RuntimeTaskKind
    /// Source-visible immutable name supplied at creation. Names are metadata
    /// of this task and are deliberately not inherited by child tasks.
    let name: String?
    let parent: RuntimeTaskID?
    let basePriority: RuntimeTaskPriority
    var effectivePriority: RuntimeTaskPriority
    /// Executor selected when the task is created. Function-level hops live
    /// on the task-owned evaluation context and restore this preference when
    /// their dynamic scope exits.
    let executorPreference: RuntimeExecutorKind
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
    var nonthrowingCallbackFailure: Error?
    fileprivate var priorityEscalationHandlers: [
        RuntimePriorityEscalationHandlerRegistration
    ] = []
    var activePriorityEscalationHandlerCount: Int {
        priorityEscalationHandlers.count
    }
    var priorityEscalationHandlerInvocationCount = 0
    var priorityEscalationHandlerFailure: Error?
    var waiters: Set<RuntimeTaskID> = []
    var waitingOnTasks: Set<RuntimeTaskID> = []
    var priorityEscalationHistory: [
        RuntimeTaskID: RuntimeTaskPriority
    ] = [:]
    var spawnedTasks: Set<RuntimeTaskID> = []
    var structuredChildren: Set<RuntimeTaskID> = []
    var structuredScopes: Set<RuntimeStructuredScopeID> = []
    var ownedTaskGroups: Set<RuntimeTaskGroupID> = []
    var ownedContinuations: Set<RuntimeContinuationID> = []
    var taskGroupID: RuntimeTaskGroupID?
    weak var sourceHandle: RuntimeTaskHandle?
    var nativeDriver: RuntimeNativeTaskDriver?
    var evaluationContext: EvaluationTaskContext?

    init(
        id: RuntimeTaskID,
        entry: RuntimeEntry,
        kind: RuntimeTaskKind,
        name: String?,
        parent: RuntimeTaskID?,
        priority: RuntimeTaskPriority,
        executorPreference: RuntimeExecutorKind,
        taskLocals: RuntimeTaskLocalStorage
    ) {
        self.id = id
        self.entry = entry
        self.kind = kind
        self.name = name
        self.parent = parent
        basePriority = priority
        effectivePriority = priority
        self.executorPreference = executorPreference
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

/// Runtime identity and structured ownership for one source task group.
/// Source-facing mutation stays on `RuntimeTaskGroup`; the scheduler record
/// keeps only task IDs and the shared lexical scope edge.
final class RuntimeTaskGroupRecord {
    let id: RuntimeTaskGroupID
    let ownerTaskID: RuntimeTaskID
    let kind: RuntimeTaskGroupKind
    let structuredScope: RuntimeStructuredScopeRecord
    var hasCancelAllRequest = false
    var hasOwnerCancellationRequest = false
    var hasChildFailureCancellationRequest = false
    var hasDiscardingBodyFailureExit = false
    var firstDiscardingFailure: RuntimeTaskOutcome?
    var childTaskIDs: [RuntimeTaskID] = []
    var completedChildTaskIDs: [RuntimeTaskID] = []
    private var completedChildTaskIDSet: Set<RuntimeTaskID> = []
    var consumedChildTaskIDs: Set<RuntimeTaskID> = []
    private var nextCompletedChildIndex = 0
    fileprivate var nextWaiter: CheckedContinuation<RuntimeTaskID, Never>?

    var pendingCompletedChildCount: Int {
        completedChildTaskIDs.count - nextCompletedChildIndex
    }

    var isCancellationRequested: Bool {
        hasCancelAllRequest || hasOwnerCancellationRequest
            || hasChildFailureCancellationRequest
    }

    /// Swift keeps a completed child in the group until its outcome is
    /// consumed. This is the same remaining-work definition used by
    /// `TaskGroup.isEmpty` and by the SDK's throwing `waitForAll` loop.
    var isEmpty: Bool {
        consumedChildTaskIDs.count == childTaskIDs.count
    }

    func publishCompletion(_ childID: RuntimeTaskID) {
        precondition(
            completedChildTaskIDSet.insert(childID).inserted,
            "task-group child \(childID) completed more than once")
        completedChildTaskIDs.append(childID)
    }

    func takeCompletion() -> RuntimeTaskID? {
        guard nextCompletedChildIndex < completedChildTaskIDs.count else {
            return nil
        }
        let childID = completedChildTaskIDs[nextCompletedChildIndex]
        nextCompletedChildIndex += 1
        precondition(
            consumedChildTaskIDs.insert(childID).inserted,
            "task-group child \(childID) was consumed more than once")
        return childID
    }

    init(
        id: RuntimeTaskGroupID,
        ownerTaskID: RuntimeTaskID,
        kind: RuntimeTaskGroupKind,
        structuredScope: RuntimeStructuredScopeRecord,
        hasOwnerCancellationRequest: Bool
    ) {
        self.id = id
        self.ownerTaskID = ownerTaskID
        self.kind = kind
        self.structuredScope = structuredScope
        self.hasOwnerCancellationRequest = hasOwnerCancellationRequest
    }
}

/// Runtime ownership for one live AsyncStream storage. Source values own the
/// storage itself; this record owns only task-wait edges, so registering a
/// stream cannot extend its source lifetime.
final class RuntimeAsyncStreamRecord {
    let id: RuntimeAsyncStreamID
    var waitingTaskIDs: Set<RuntimeTaskID> = []

    init(id: RuntimeAsyncStreamID) {
        self.id = id
    }
}

/// Stable runtime identity for one source actor instance. The source reference
/// graph owns the instance and its property boxes; the runtime record remains
/// non-owning so registering an executor cannot extend source actor lifetime.
/// The mailbox serializes source-task entry into actor execution segments;
/// it is deliberately independent from the physical MainActor host on which
/// the cooperative evaluator currently runs.
final class RuntimeActorRecord {
    let id: RuntimeActorID
    weak var instance: Instance?
    /// Runtime-task identity that currently owns this actor's non-suspending
    /// execution segment. Keeping it on the actor record prevents the
    /// physical MainActor host from being mistaken for source-actor ownership.
    fileprivate(set) var executorOwnerTaskID: RuntimeTaskID?
    fileprivate var executorOwnerDepth = 0
    fileprivate var mailbox: [RuntimeActorMailboxWaiter] = []

    var mailboxTaskIDs: [RuntimeTaskID] { mailbox.map(\.taskID) }

    init(id: RuntimeActorID, instance: Instance) {
        self.id = id
        self.instance = instance
    }
}

struct RuntimeActorExecutorLease: Equatable {
    let actorID: RuntimeActorID
    let taskID: RuntimeTaskID
}

/// Complete depth-counted actor segment parked while one source task is
/// suspended. Nested same-actor invocations contribute one depth apiece; the
/// whole segment is released together and restored before source evaluation
/// resumes so outstanding invocation leases remain balanced.
struct RuntimeActorExecutorSuspension: Equatable {
    let actorID: RuntimeActorID
    let taskID: RuntimeTaskID
    let depth: Int
}

/// Balanced runtime wait plus any actor segment released by that wait. The
/// low-level task state transition and executor ownership move together so a
/// new suspension kind cannot accidentally park a task while retaining an
/// actor.
struct RuntimeTaskSuspensionLease: Equatable {
    let taskID: RuntimeTaskID
    let reason: RuntimeSuspension
    let actorExecutor: RuntimeActorExecutorSuspension?
}

private final class RuntimeActorMailboxWaiter {
    let taskID: RuntimeTaskID
    let ownerDepth: Int
    let continuation: CheckedContinuation<Void, Never>

    init(
        taskID: RuntimeTaskID,
        ownerDepth: Int = 1,
        continuation: CheckedContinuation<Void, Never>
    ) {
        self.taskID = taskID
        self.ownerDepth = ownerDepth
        self.continuation = continuation
    }
}

final class CooperativeConcurrencyRuntime {
    private static let maximumActorMailboxWaiters = 1_024
    private static let maximumLiveContinuations = 1_024

    let clock: any RuntimeClock
    let diagnostics: RuntimeDiagnosticSink
    private var nextSessionID: UInt64 = 1
    private var nextTaskID: UInt64 = 1
    private var nextActorID: UInt64 = 1
    private var nextStructuredScopeID: UInt64 = 1
    private var nextTaskGroupID: UInt64 = 1
    private var nextAsyncStreamID: UInt64 = 1
    private var nextContinuationID: UInt64 = 1
    private var nextHostOperationID: UInt64 = 1
    private var nextCancellationHandlerID: UInt64 = 1
    private var nextPriorityEscalationHandlerID: UInt64 = 1
    private var nextEventSequence: UInt64 = 1
    private(set) var records: [RuntimeTaskID: RuntimeTaskRecord] = [:]
    private(set) var structuredScopes: [
        RuntimeStructuredScopeID: RuntimeStructuredScopeRecord
    ] = [:]
    private(set) var taskGroups: [
        RuntimeTaskGroupID: RuntimeTaskGroupRecord
    ] = [:]
    private(set) var asyncStreams: [
        RuntimeAsyncStreamID: RuntimeAsyncStreamRecord
    ] = [:]
    private(set) var continuations: [
        RuntimeContinuationID: RuntimeContinuationRecord
    ] = [:]
    private(set) var hostOperations: [HostOperationID: RuntimeTaskID] = [:]
    private var hostOperationSuspensions: [
        HostOperationID: RuntimeTaskSuspensionLease
    ] = [:]
    private(set) var actors: [RuntimeActorID: RuntimeActorRecord] = [:]
    private(set) var totalAsyncStreamsCreated = 0
    private(set) var asyncStreamSuspensionCount = 0
    private(set) var totalContinuationsCreated = 0
    private(set) var continuationSuspensionCount = 0
    /// Swift callback types such as `AsyncStream.Continuation.onTermination`
    /// are nonthrowing, but evaluating their source bodies can still uncover
    /// an interpreter/runtime failure. Destruction cannot throw, so retain the
    /// first such failure until the owning evaluator reaches a throwing safe
    /// point instead of silently discarding it from `deinit`.
    private var pendingUnownedNonthrowingCallbackFailure: Error?

    init(
        clock: any RuntimeClock = ContinuousRuntimeClock(),
        diagnostics: RuntimeDiagnosticSink = RuntimeDiagnosticSink()
    ) {
        self.clock = clock
        self.diagnostics = diagnostics
    }

    func createEntry(
        kind: RuntimeEntry.Kind,
        heap: RuntimeHeap? = nil,
        programState: RuntimeProgramState? = nil,
        programPlan: ResolvedProgramPlan? = nil,
        programMetadata: ParsedProgramMetadata? = nil,
        interpreter: Interpreter? = nil
    ) -> RuntimeEntry {
        let id = RuntimeSessionID(rawValue: nextSessionID)
        nextSessionID += 1
        return RuntimeEntry(
            id: id,
            kind: kind,
            heap: heap,
            programState: programState,
            programPlan: programPlan,
            programMetadata: programMetadata,
            interpreter: interpreter)
    }

    func recordNonthrowingCallbackFailure(
        _ error: Error,
        taskID: RuntimeTaskID?
    ) {
        if let taskID, let record = records[taskID] {
            if record.nonthrowingCallbackFailure == nil {
                record.nonthrowingCallbackFailure = error
            }
            return
        }
        if pendingUnownedNonthrowingCallbackFailure == nil {
            pendingUnownedNonthrowingCallbackFailure = error
        }
    }

    func throwNonthrowingCallbackFailure(
        for taskID: RuntimeTaskID?
    ) throws {
        if let taskID,
           let failure = records[taskID]?.nonthrowingCallbackFailure {
            records[taskID]?.nonthrowingCallbackFailure = nil
            throw failure
        }
        guard let failure = pendingUnownedNonthrowingCallbackFailure else {
            return
        }
        pendingUnownedNonthrowingCallbackFailure = nil
        throw failure
    }

    func registerActor(_ instance: Instance) -> RuntimeActorID {
        precondition(instance.symbol.isActor, "only actor instances may register")
        precondition(instance.actorID == nil, "actor instance registered twice")
        let id = RuntimeActorID(rawValue: nextActorID)
        nextActorID += 1
        let record = RuntimeActorRecord(id: id, instance: instance)
        precondition(
            actors.updateValue(record, forKey: id) == nil,
            "duplicate runtime actor ID \(id)")
        return id
    }

    func releaseActor(_ id: RuntimeActorID) {
        guard let record = actors[id] else { return }
        precondition(
            record.executorOwnerTaskID == nil && record.mailbox.isEmpty,
            "cannot release actor \(id) while its executor is active")
        actors.removeValue(forKey: id)
    }

    /// Acquire one source actor's mutually-exclusive executor
    /// segment. Re-entry by the same source task is depth-counted; competing
    /// source tasks become explicit runtime waiters instead of relying on the
    /// evaluator's incidental physical MainActor serialization.
    func acquireActorExecutor(
        _ actorID: RuntimeActorID,
        for taskID: RuntimeTaskID
    ) async throws -> RuntimeActorExecutorLease {
        guard let actor = actors[actorID], actor.instance != nil else {
            throw RuntimeError(
                message: "cannot enter released actor executor \(actorID)",
                fatal: true)
        }
        guard let task = records[taskID], task.state == .running else {
            throw RuntimeError(
                message: "actor executor entry requires a running runtime task",
                fatal: true)
        }

        if actor.executorOwnerTaskID == nil {
            actor.executorOwnerTaskID = taskID
            actor.executorOwnerDepth = 1
            return RuntimeActorExecutorLease(actorID: actorID, taskID: taskID)
        }
        if actor.executorOwnerTaskID == taskID {
            actor.executorOwnerDepth += 1
            return RuntimeActorExecutorLease(actorID: actorID, taskID: taskID)
        }
        guard actor.mailbox.count < Self.maximumActorMailboxWaiters else {
            throw RuntimeError(
                message: "actor executor mailbox exceeded "
                    + "\(Self.maximumActorMailboxWaiters) waiters",
                fatal: true)
        }
        precondition(
            !actor.mailbox.contains { $0.taskID == taskID },
            "runtime task \(taskID) queued twice for actor \(actorID)")

        let reason = RuntimeSuspension.waitingForActor(actorID)
        suspend(taskID, for: reason)
        await withCheckedContinuation { continuation in
            actor.mailbox.append(RuntimeActorMailboxWaiter(
                taskID: taskID, continuation: continuation))
        }
        precondition(
            actor.executorOwnerTaskID == taskID
                && actor.executorOwnerDepth == 1,
            "actor \(actorID) resumed \(taskID) without ownership")
        return RuntimeActorExecutorLease(actorID: actorID, taskID: taskID)
    }

    /// Release a depth-counted segment and hand ownership directly to one
    /// waiter. FIFO is an internal deterministic scheduling policy, not a
    /// source-level ordering guarantee exposed by this runtime slice.
    func releaseActorExecutor(_ lease: RuntimeActorExecutorLease) {
        guard let actor = actors[lease.actorID] else {
            preconditionFailure(
                "cannot release missing actor executor \(lease.actorID)")
        }
        precondition(
            actor.executorOwnerTaskID == lease.taskID
                && actor.executorOwnerDepth > 0,
            "runtime task \(lease.taskID) does not own actor \(lease.actorID)")
        if actor.executorOwnerDepth > 1 {
            actor.executorOwnerDepth -= 1
            return
        }

        actor.executorOwnerTaskID = nil
        actor.executorOwnerDepth = 0
        handOffActorExecutor(actor)
    }

    /// Release every nested lease held by one source task at a real
    /// suspension boundary. At most one actor may be owned by a task: an
    /// awaited cross-executor call releases its caller before acquiring its
    /// callee.
    func suspendOwnedActorExecutor(
        for taskID: RuntimeTaskID
    ) -> RuntimeActorExecutorSuspension? {
        let owned = actors.values.filter { $0.executorOwnerTaskID == taskID }
        precondition(
            owned.count <= 1,
            "runtime task \(taskID) owns multiple actor executors")
        guard let actor = owned.first else { return nil }
        precondition(
            actor.executorOwnerDepth > 0,
            "actor \(actor.id) has an owner without positive depth")
        let suspension = RuntimeActorExecutorSuspension(
            actorID: actor.id,
            taskID: taskID,
            depth: actor.executorOwnerDepth)
        actor.executorOwnerTaskID = nil
        actor.executorOwnerDepth = 0
        handOffActorExecutor(actor)
        return suspension
    }

    /// Requeue a suspended actor continuation and restore its complete nested
    /// depth before the evaluator may execute another source instruction.
    /// Resumption is not a fresh source message and therefore cannot be
    /// rejected by the admission bound that applies to newly-entering calls.
    func resumeActorExecutor(
        _ suspension: RuntimeActorExecutorSuspension
    ) async {
        guard let actor = actors[suspension.actorID], actor.instance != nil else {
            preconditionFailure(
                "cannot resume released actor executor \(suspension.actorID)")
        }
        guard let task = records[suspension.taskID], task.state == .running else {
            preconditionFailure(
                "actor executor resume requires a running runtime task")
        }
        precondition(
            suspension.depth > 0,
            "actor executor suspension must retain positive depth")
        precondition(
            actor.executorOwnerTaskID != suspension.taskID,
            "runtime task \(suspension.taskID) resumed an actor it already owns")

        if actor.executorOwnerTaskID == nil {
            actor.executorOwnerTaskID = suspension.taskID
            actor.executorOwnerDepth = suspension.depth
            return
        }

        precondition(
            !actor.mailbox.contains { $0.taskID == suspension.taskID },
            "runtime task \(suspension.taskID) queued twice for actor "
                + "\(suspension.actorID)")
        let reason = RuntimeSuspension.waitingForActor(suspension.actorID)
        suspend(suspension.taskID, for: reason)
        await withCheckedContinuation { continuation in
            actor.mailbox.append(RuntimeActorMailboxWaiter(
                taskID: suspension.taskID,
                ownerDepth: suspension.depth,
                continuation: continuation))
        }
        precondition(
            actor.executorOwnerTaskID == suspension.taskID
                && actor.executorOwnerDepth == suspension.depth,
            "actor \(suspension.actorID) resumed \(suspension.taskID) "
                + "without restoring ownership")
    }

    /// Synchronous host re-entry cannot wait for a contended actor without
    /// blocking the cooperative runtime. It may resume only when ownership is
    /// immediately available; otherwise the callback fails closed and leaves
    /// the original host wait intact.
    private func resumeActorExecutorImmediately(
        _ suspension: RuntimeActorExecutorSuspension
    ) throws {
        guard let actor = actors[suspension.actorID], actor.instance != nil else {
            throw RuntimeError(
                message: "cannot resume released actor executor "
                    + "\(suspension.actorID)",
                fatal: true)
        }
        guard let task = records[suspension.taskID], task.state == .running,
              suspension.depth > 0 else {
            throw RuntimeError(
                message: "synchronous actor resume requires a running task "
                    + "and positive ownership depth",
                fatal: true)
        }
        guard actor.executorOwnerTaskID == nil else {
            throw RuntimeError(
                message: "synchronous host callback cannot resume on busy "
                    + "actor executor \(suspension.actorID)",
                fatal: true)
        }
        actor.executorOwnerTaskID = suspension.taskID
        actor.executorOwnerDepth = suspension.depth
    }

    private func handOffActorExecutor(_ actor: RuntimeActorRecord) {
        guard !actor.mailbox.isEmpty else { return }
        precondition(
            actor.executorOwnerTaskID == nil
                && actor.executorOwnerDepth == 0,
            "actor \(actor.id) cannot hand off while owned")
        let waiter = actor.mailbox.removeFirst()
        actor.executorOwnerTaskID = waiter.taskID
        actor.executorOwnerDepth = waiter.ownerDepth
        resume(waiter.taskID, from: .waitingForActor(actor.id))
        waiter.continuation.resume()
    }

    func createTask(
        entry: RuntimeEntry,
        kind: RuntimeTaskKind,
        parent: RuntimeTaskID?,
        priority: RuntimeTaskPriority,
        executorPreference: RuntimeExecutorKind,
        taskLocals: RuntimeTaskLocalStorage,
        name: String?
    ) -> RuntimeTaskRecord {
        let id = RuntimeTaskID(rawValue: nextTaskID)
        nextTaskID += 1
        let record = RuntimeTaskRecord(
            id: id, entry: entry, kind: kind, name: name,
            parent: parent,
            priority: priority, executorPreference: executorPreference,
            taskLocals: taskLocals)
        records[id] = record
        if let parent, let parentRecord = records[parent] {
            precondition(
                parentRecord.entry === entry,
                "runtime child task must retain its parent's entry")
            // Creation/inheritance and structured ownership are deliberately
            // separate edges. `Task {}` has a creator but is not a structured
            // child and must not receive cancellation through this relation.
            parentRecord.spawnedTasks.insert(id)
            if kind.isStructuredChild {
                parentRecord.structuredChildren.insert(id)
                // Structured cancellation is a state relationship, not only
                // an edge-triggered notification. A child created after its
                // owner was cancelled must start cancelled as native Swift
                // does; later native-task attachment forwards this request.
                if parentRecord.cancellation.isRequested {
                    requestCancellation(
                        record, source: .structuredParent)
                }
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
        ownerTaskID: RuntimeTaskID,
        kind: RuntimeTaskGroupKind
    ) -> RuntimeTaskGroupRecord {
        let scope = createStructuredScope(
            ownerTaskID: ownerTaskID, kind: .taskGroup)
        let id = RuntimeTaskGroupID(rawValue: nextTaskGroupID)
        nextTaskGroupID += 1
        guard let owner = records[ownerTaskID] else {
            preconditionFailure(
                "task group \(id) lost owner task \(ownerTaskID)")
        }
        let group = RuntimeTaskGroupRecord(
            id: id,
            ownerTaskID: ownerTaskID,
            kind: kind,
            structuredScope: scope,
            hasOwnerCancellationRequest: owner.cancellation.isRequested)
        precondition(
            taskGroups.updateValue(group, forKey: id) == nil,
            "duplicate task group ID \(id)")
        precondition(
            owner.ownedTaskGroups.insert(id).inserted,
            "duplicate owner edge for task group \(id)")
        return group
    }

    func createAsyncStream() -> RuntimeAsyncStreamID {
        let id = RuntimeAsyncStreamID(rawValue: nextAsyncStreamID)
        nextAsyncStreamID += 1
        let record = RuntimeAsyncStreamRecord(id: id)
        precondition(
            asyncStreams.updateValue(record, forKey: id) == nil,
            "duplicate async stream ID \(id)")
        totalAsyncStreamsCreated += 1
        return id
    }

    func beginWaitingForAsyncStream(
        _ streamID: RuntimeAsyncStreamID,
        taskID: RuntimeTaskID
    ) -> RuntimeTaskSuspensionLease {
        guard let stream = asyncStreams[streamID],
              let task = records[taskID], task.state == .running else {
            preconditionFailure(
                "task \(taskID) cannot wait on inactive \(streamID)")
        }
        precondition(
            stream.waitingTaskIDs.insert(taskID).inserted,
            "task \(taskID) is already waiting on \(streamID)")
        asyncStreamSuspensionCount += 1
        return beginTaskSuspension(
            taskID, for: .waitingForStream(streamID))
    }

    func endWaitingForAsyncStream(
        _ streamID: RuntimeAsyncStreamID,
        taskID: RuntimeTaskID,
        lease: RuntimeTaskSuspensionLease
    ) async {
        guard let stream = asyncStreams[streamID] else {
            preconditionFailure(
                "task \(taskID) resumed from inactive \(streamID)")
        }
        precondition(
            stream.waitingTaskIDs.remove(taskID) != nil,
            "task \(taskID) was not waiting on \(streamID)")
        await endTaskSuspension(lease)
    }

    func asyncStreamHasWaiters(_ id: RuntimeAsyncStreamID) -> Bool {
        asyncStreams[id]?.waitingTaskIDs.isEmpty == false
    }

    func closeAsyncStream(_ id: RuntimeAsyncStreamID) {
        guard let stream = asyncStreams[id] else { return }
        precondition(
            stream.waitingTaskIDs.isEmpty,
            "cannot close \(id) with active consumers")
        asyncStreams.removeValue(forKey: id)
    }

    func createContinuation(
        ownerTaskID: RuntimeTaskID,
        requiredExecutor: RuntimeExecutorKind
    ) throws -> RuntimeContinuationRecord {
        guard continuations.count < Self.maximumLiveContinuations else {
            throw RuntimeError(
                message: "interpreted continuation limit exceeded",
                fatal: true)
        }
        guard let owner = records[ownerTaskID],
              owner.state == .running else {
            throw RuntimeError(
                message: "checked continuation requires a running owner task",
                fatal: true)
        }
        let id = RuntimeContinuationID(rawValue: nextContinuationID)
        nextContinuationID += 1
        let record = RuntimeContinuationRecord(
            id: id,
            ownerTaskID: ownerTaskID,
            requiredExecutor: requiredExecutor)
        precondition(
            continuations.updateValue(record, forKey: id) == nil,
            "duplicate runtime continuation ID \(id)")
        precondition(
            owner.ownedContinuations.insert(id).inserted,
            "duplicate owner edge for \(id)")
        totalContinuationsCreated += 1
        return record
    }

    func resumeContinuation(
        _ id: RuntimeContinuationID,
        returning value: RuntimeValue
    ) throws {
        try resolveContinuation(
            id, as: .resumed(value.copiedForValueSemantics()))
    }

    func resumeContinuation(
        _ id: RuntimeContinuationID,
        throwing value: RuntimeValue
    ) throws {
        try resolveContinuation(
            id, as: .failed(value.copiedForValueSemantics()))
    }

    private func resolveContinuation(
        _ id: RuntimeContinuationID,
        as outcome: RuntimeContinuationState
    ) throws {
        guard let record = continuations[id] else {
            throw RuntimeError(
                message: "checked continuation \(id) is no longer active",
                fatal: true)
        }
        guard case .pending = record.state else {
            throw RuntimeError(
                message: "checked continuation \(id) resumed more than once",
                fatal: true)
        }
        record.state = outcome
        let waiter = record.nativeWaiter
        record.nativeWaiter = nil
        waiter?.resume()
    }

    func awaitContinuation(
        _ record: RuntimeContinuationRecord
    ) async throws -> RuntimeValue {
        precondition(
            continuations[record.id] === record,
            "cannot await inactive \(record.id)")

        if case .pending = record.state {
            let continuationID = record.id
            let lease = beginTaskSuspension(
                record.ownerTaskID,
                for: .waitingForContinuation(continuationID))
            record.suspensionLease = lease
            continuationSuspensionCount += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in
                    if case .pending = record.state {
                        precondition(
                            record.nativeWaiter == nil,
                            "\(record.id) installed more than one native waiter")
                        record.nativeWaiter = waiter
                    } else {
                        waiter.resume()
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.abortContinuationForNativeCancellation(continuationID)
                }
            }
            record.nativeWaiter = nil
            await endTaskSuspension(lease)
            record.suspensionLease = nil
        }

        let outcome = record.state
        let ownerExecutor = records[record.ownerTaskID]?
            .evaluationContext?.currentExecutor
        precondition(
            ownerExecutor == record.requiredExecutor,
            "\(record.id) resumed on \(String(describing: ownerExecutor)) "
                + "instead of \(record.requiredExecutor)")
        closeContinuation(record)
        switch outcome {
        case .resumed(let value):
            return value
        case .failed(let value):
            throw InterpretedThrow(value: value)
        case .aborted:
            throw InterpreterSessionAbort()
        case .pending:
            preconditionFailure("\(record.id) woke without an outcome")
        }
    }

    func discardContinuation(_ record: RuntimeContinuationRecord) {
        precondition(
            record.nativeWaiter == nil && record.suspensionLease == nil,
            "cannot discard a suspended continuation")
        closeContinuation(record)
    }

    private func closeContinuation(_ record: RuntimeContinuationRecord) {
        precondition(
            record.nativeWaiter == nil && record.suspensionLease == nil,
            "cannot close suspended \(record.id)")
        precondition(
            continuations.removeValue(forKey: record.id) === record,
            "cannot close inactive \(record.id)")
        guard let owner = records[record.ownerTaskID] else {
            preconditionFailure("\(record.id) lost owner \(record.ownerTaskID)")
        }
        precondition(
            owner.ownedContinuations.remove(record.id) != nil,
            "\(record.id) lost its owner edge")
    }

    private func abortContinuationForNativeCancellation(
        _ id: RuntimeContinuationID
    ) {
        guard let continuation = continuations[id],
              let owner = records[continuation.ownerTaskID],
              owner.kind == .root || requiresSessionAbort(owner.id) else {
            return
        }
        abortContinuation(continuation)
    }

    private func abortContinuationsOwned(by taskID: RuntimeTaskID) {
        guard let owner = records[taskID] else { return }
        for id in Array(owner.ownedContinuations) {
            guard let continuation = continuations[id] else {
                preconditionFailure("task \(taskID) owns inactive \(id)")
            }
            abortContinuation(continuation)
        }
    }

    private func abortContinuation(_ record: RuntimeContinuationRecord) {
        guard case .pending = record.state else { return }
        record.sourceToken?.invalidateForInfrastructureAbort()
        record.state = .aborted
        let waiter = record.nativeWaiter
        record.nativeWaiter = nil
        waiter?.resume()
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
        guard taskGroups[group.id] === group,
              let child = records[childID] else {
            preconditionFailure("cannot add a child to inactive \(group.id)")
        }
        precondition(
            !group.structuredScope.childTaskIDs.contains(childID),
            "duplicate child \(childID) in \(group.id)")
        precondition(
            child.taskGroupID == nil,
            "task \(childID) already belongs to a task group")
        addStructuredChild(childID, to: group.structuredScope)
        child.taskGroupID = group.id
        group.childTaskIDs.append(childID)
        if child.state.isCompleted {
            publishTaskGroupCompletion(child)
        }
    }

    /// Roll back the ownership half of a group-child launch transaction.
    /// This is legal only before the native driver has begun; successful and
    /// completed children are removed exclusively by normal group teardown.
    func removePendingGroupChild(
        _ childID: RuntimeTaskID,
        from group: RuntimeTaskGroupRecord
    ) {
        guard taskGroups[group.id] === group,
              let child = records[childID],
              child.taskGroupID == group.id,
              child.state == .pending,
              group.childTaskIDs.last == childID,
              !group.completedChildTaskIDs.contains(childID) else {
            preconditionFailure(
                "cannot roll back started task-group child \(childID)")
        }
        group.childTaskIDs.removeLast()
        precondition(
            group.structuredScope.childTaskIDs.remove(childID) != nil,
            "pending child \(childID) lost its structured-scope edge")
        child.taskGroupID = nil
    }

    func nextTaskGroupOutcome(
        _ waiterID: RuntimeTaskID,
        on group: RuntimeTaskGroupRecord
    ) async -> RuntimeTaskOutcome? {
        guard taskGroups[group.id] === group,
              group.ownerTaskID == waiterID else {
            preconditionFailure(
                "task \(waiterID) cannot consume inactive \(group.id)")
        }
        if let outcome = takeCompletedTaskGroupOutcome(from: group) {
            return outcome
        }
        if group.consumedChildTaskIDs.count == group.childTaskIDs.count {
            return nil
        }

        let suspension = beginWaitingForTaskGroup(waiterID, on: group)
        precondition(
            suspension != nil,
            "task group has an undelivered result but no active child")
        let childID = await withCheckedContinuation { continuation in
            precondition(
                group.nextWaiter == nil,
                "task group cannot have multiple next waiters")
            group.nextWaiter = continuation
        }
        await endWaitingForTaskGroup(
            waiterID, on: group, from: suspension)
        guard let outcome = records[childID]?.outcome else {
            preconditionFailure(
                "completed task-group child \(childID) has no outcome")
        }
        return outcome
    }

    func drainTaskGroupOutcomes(_ group: RuntimeTaskGroupRecord) {
        guard taskGroups[group.id] === group else {
            preconditionFailure(
                "cannot drain outcomes from inactive \(group.id)")
        }
        precondition(
            group.childTaskIDs.allSatisfy {
                records[$0]?.state.isCompleted == true
            },
            "cannot drain \(group.id) while a child is active")
        while group.takeCompletion() != nil {}
        precondition(
            group.consumedChildTaskIDs.count == group.childTaskIDs.count,
            "draining \(group.id) did not consume every result")
    }

    func beginWaitingForTaskGroup(
        _ waiterID: RuntimeTaskID,
        on group: RuntimeTaskGroupRecord
    ) -> RuntimeTaskSuspensionLease? {
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
        return beginTaskSuspension(waiterID, for: suspension)
    }

    func endWaitingForTaskGroup(
        _ waiterID: RuntimeTaskID,
        on group: RuntimeTaskGroupRecord,
        from suspension: RuntimeTaskSuspensionLease?
    ) async {
        guard let suspension else { return }
        for childID in group.childTaskIDs {
            guard let child = records[childID] else { continue }
            endWaiting(waiterID, on: child)
        }
        await endTaskSuspension(suspension)
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
        precondition(
            group.nextWaiter == nil,
            "cannot close \(group.id) with an active next waiter")
        precondition(
            group.completedChildTaskIDs.count == group.childTaskIDs.count,
            "cannot close \(group.id) before every outcome is published")
        guard let owner = records[group.ownerTaskID] else {
            preconditionFailure(
                "task group \(group.id) lost owner task \(group.ownerTaskID)")
        }
        precondition(
            owner.ownedTaskGroups.remove(group.id) != nil,
            "task group \(group.id) is absent from its owner")
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
        precondition(
            record.nativeDriver == nil,
            "cannot attach more than one native driver to \(record.id)")
        record.nativeDriver = RuntimeNativeTaskDriver(task: nativeTask)
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
        publishTaskGroupCompletion(record)
    }

    func fail(_ record: RuntimeTaskRecord, with error: Error) {
        guard record.state != .cancelled else { return }
        record.failureDescription = String(describing: error)
        if let thrown = error as? InterpretedThrow {
            record.outcome = .failure(
                thrown.value,
                failureType: HostRuntimeTypeSystem.typeName(of: thrown.value))
        } else if let runtimeError = error as? RuntimeError {
            record.outcome = .failure(
                .native(runtimeError), failureType: "RuntimeError")
        } else {
            record.outcome = .failure(
                .native(String(describing: error)),
                failureType: String(describing: type(of: error)))
        }
        record.state = .failed
        record.suspension = nil
        record.evaluationContext = nil
        publishTaskGroupCompletion(record)
    }

    func requestCancellation(
        _ record: RuntimeTaskRecord,
        source: RuntimeCancellationSource
    ) {
        let wasAlreadyRequested = record.cancellation.isRequested
        let alreadyRequestedFromSource =
            record.cancellation.sources.contains(source)
        record.cancellation.request(
            from: source, sequence: takeEventSequence())
        if source == .sessionPolicy || source == .hostTask {
            abortContinuationsOwned(by: record.id)
        }
        // Cancellation is orthogonal to completion in Swift. A handle may be
        // cancelled after its task reaches a terminal state; that updates the
        // handle's cancellation bit without changing the immutable outcome or
        // re-running cancellation side effects for completed work.
        guard !record.state.isCompleted else { return }
        for groupID in record.ownedTaskGroups {
            guard let group = taskGroups[groupID] else {
                preconditionFailure(
                    "task \(record.id) owns inactive task group \(groupID)")
            }
            group.hasOwnerCancellationRequest = true
        }
        record.nativeDriver?.task.cancel()
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

    func addPriorityEscalationHandler(
        to taskID: RuntimeTaskID,
        invoke: @escaping @MainActor (
            RuntimeTaskPriority, RuntimeTaskPriority
        ) throws -> Void
    ) -> RuntimePriorityEscalationHandlerID {
        guard let record = records[taskID], !record.state.isCompleted else {
            preconditionFailure(
                "cannot register a priority escalation handler on inactive "
                    + "task \(taskID)")
        }
        let id = RuntimePriorityEscalationHandlerID(
            rawValue: nextPriorityEscalationHandlerID)
        nextPriorityEscalationHandlerID += 1
        record.priorityEscalationHandlers.append(
            RuntimePriorityEscalationHandlerRegistration(
                id: id, invoke: invoke))
        return id
    }

    func removePriorityEscalationHandler(
        _ handlerID: RuntimePriorityEscalationHandlerID,
        from taskID: RuntimeTaskID
    ) {
        guard let record = records[taskID] else { return }
        record.priorityEscalationHandlers.removeAll { $0.id == handlerID }
    }

    func throwPriorityEscalationHandlerFailure(
        for taskID: RuntimeTaskID
    ) throws {
        guard let failure = records[taskID]?
                .priorityEscalationHandlerFailure else { return }
        throw failure
    }

    func completeCancellation(_ record: RuntimeTaskRecord) {
        guard !record.state.isCompleted else { return }
        record.cancellation.observe(sequence: takeEventSequence())
        record.outcome = .cancelled
        record.state = .cancelled
        record.suspension = nil
        record.evaluationContext = nil
        publishTaskGroupCompletion(record)
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
            !hostOperationSuspensions.values.contains { $0.taskID == id },
            "cannot release runtime task \(id) with a parked host suspension")
        precondition(
            records[id]?.structuredScopes.isEmpty != false,
            "cannot release runtime task \(id) with an active structured scope")
        precondition(
            records[id]?.ownedTaskGroups.isEmpty != false,
            "cannot release runtime task \(id) with an active task group")
        precondition(
            records[id]?.ownedContinuations.isEmpty != false,
            "cannot release runtime task \(id) with an active continuation")
        precondition(
            asyncStreams.values.allSatisfy {
                !$0.waitingTaskIDs.contains(id)
            },
            "cannot release runtime task \(id) with an async-stream wait")
        precondition(
            !actors.values.contains {
                $0.executorOwnerTaskID == id
                    || $0.mailbox.contains { $0.taskID == id }
            },
            "cannot release runtime task \(id) with an actor-executor edge")
        guard let record = records[id] else { return }
        clock.cancelSleep(task: id)
        record.cancellationHandlers.removeAll(keepingCapacity: false)
        record.priorityEscalationHandlers.removeAll(keepingCapacity: false)
        for waiterID in record.waiters {
            records[waiterID]?.waitingOnTasks.remove(id)
        }
        record.waiters.removeAll(keepingCapacity: false)
        for awaitedID in record.waitingOnTasks {
            records[awaitedID]?.waiters.remove(id)
        }
        record.waitingOnTasks.removeAll(keepingCapacity: false)
        if let handle = record.sourceHandle {
            handle.detachFromRuntime(
                record,
                nextCancellationSequence: takeEventSequence())
        }
        record.nativeDriver = nil
        record.sourceHandle = nil
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
        // The evaluator budget bounds consecutive non-suspending work. A
        // registered suspension is a real cooperative progress boundary, so
        // polling loops such as `while !ready { await Task.yield() }` must not
        // fail merely because another task was delayed by host contention.
        // Tight loops without a suspension still exhaust the same budget.
        record.evaluationContext?.steps = 0
    }

    /// Canonical semantic suspension entry. Actor ownership is released only
    /// after the task is durably represented as waiting, so another actor
    /// message can never observe two running owners.
    func beginTaskSuspension(
        _ id: RuntimeTaskID,
        for reason: RuntimeSuspension
    ) -> RuntimeTaskSuspensionLease {
        suspend(id, for: reason)
        return RuntimeTaskSuspensionLease(
            taskID: id,
            reason: reason,
            actorExecutor: suspendOwnedActorExecutor(for: id))
    }

    /// Canonical semantic resume. The runtime task becomes runnable, then
    /// waits for its former actor if necessary; source evaluation returns from
    /// this function only after executor ownership has been restored.
    func endTaskSuspension(
        _ lease: RuntimeTaskSuspensionLease
    ) async {
        resume(lease.taskID, from: lease.reason)
        if let actorExecutor = lease.actorExecutor {
            await resumeActorExecutor(actorExecutor)
        }
    }

    /// Synchronous host callbacks use the same balanced wait token but cannot
    /// enqueue and await an actor. Failure restores the task's original wait
    /// state so the host operation remains internally consistent.
    private func endTaskSuspensionImmediately(
        _ lease: RuntimeTaskSuspensionLease
    ) throws {
        resume(lease.taskID, from: lease.reason)
        do {
            if let actorExecutor = lease.actorExecutor {
                try resumeActorExecutorImmediately(actorExecutor)
            }
        } catch {
            suspend(lease.taskID, for: lease.reason)
            throw error
        }
    }

    func beginHostOperation(for taskID: RuntimeTaskID) -> HostOperationID {
        let operationID = HostOperationID(rawValue: nextHostOperationID)
        nextHostOperationID += 1
        precondition(
            hostOperations.updateValue(taskID, forKey: operationID) == nil,
            "duplicate host operation ID \(operationID)")
        let suspension = beginTaskSuspension(
            taskID, for: .awaitingHost(operationID))
        precondition(
            hostOperationSuspensions.updateValue(
                suspension, forKey: operationID) == nil,
            "duplicate host-operation suspension \(operationID)")
        return operationID
    }

    func endHostOperation(
        _ operationID: HostOperationID, for taskID: RuntimeTaskID
    ) async {
        precondition(
            hostOperations.removeValue(forKey: operationID) == taskID,
            "host operation \(operationID) has the wrong runtime task")
        guard let suspension = hostOperationSuspensions.removeValue(
            forKey: operationID) else {
            preconditionFailure(
                "host operation \(operationID) lost its suspension")
        }
        await endTaskSuspension(suspension)
    }

    func resumeHostOperationForCallback(
        _ operationID: HostOperationID, taskID: RuntimeTaskID
    ) async {
        precondition(
            hostOperations[operationID] == taskID,
            "cannot re-enter inactive host operation \(operationID)")
        guard let suspension = hostOperationSuspensions.removeValue(
            forKey: operationID) else {
            preconditionFailure(
                "host operation \(operationID) lost its suspension")
        }
        await endTaskSuspension(suspension)
    }

    func resumeHostOperationForSynchronousCallback(
        _ operationID: HostOperationID, taskID: RuntimeTaskID
    ) throws {
        precondition(
            hostOperations[operationID] == taskID,
            "cannot re-enter inactive host operation \(operationID)")
        guard let suspension = hostOperationSuspensions.removeValue(
            forKey: operationID) else {
            preconditionFailure(
                "host operation \(operationID) lost its suspension")
        }
        do {
            try endTaskSuspensionImmediately(suspension)
        } catch {
            precondition(
                hostOperationSuspensions.updateValue(
                    suspension, forKey: operationID) == nil,
                "host operation \(operationID) restored twice")
            throw error
        }
    }

    func suspendHostOperationAfterCallback(
        _ operationID: HostOperationID, taskID: RuntimeTaskID
    ) {
        precondition(
            hostOperations[operationID] == taskID,
            "cannot leave inactive host operation \(operationID)")
        let suspension = beginTaskSuspension(
            taskID, for: .awaitingHost(operationID))
        precondition(
            hostOperationSuspensions.updateValue(
                suspension, forKey: operationID) == nil,
            "host operation \(operationID) suspended twice")
    }

    var activeRecordCount: Int { records.count }
    var activeActorCount: Int { actors.count }
    var activeHostOperationCount: Int {
        precondition(
            hostOperationSuspensions.allSatisfy { operationID, lease in
                hostOperations[operationID] == lease.taskID
            },
            "parked host suspension has no matching active operation")
        return hostOperations.count
    }
    var activeStructuredScopeCount: Int { structuredScopes.count }
    var activeTaskGroupCount: Int { taskGroups.count }
    var activeAsyncStreamCount: Int { asyncStreams.count }
    var activeContinuationCount: Int { continuations.count }

    private func invokeCancellationHandlers(on record: RuntimeTaskRecord) {
        // The same-source Swift 6.3.3 probe establishes inner-to-outer
        // invocation for simultaneously active nested registrations. Taking
        // the reverse view also leaves one-shot state on each registration,
        // so repeated cancellation cannot invoke either handler again.
        for registration in record.cancellationHandlers.reversed() {
            invokeCancellationHandler(registration, on: record)
        }
    }

    private func publishTaskGroupCompletion(_ child: RuntimeTaskRecord) {
        guard let groupID = child.taskGroupID,
              let group = taskGroups[groupID] else { return }
        precondition(
            group.structuredScope.childTaskIDs.contains(child.id),
            "completed child \(child.id) is absent from \(group.id)")
        group.publishCompletion(child.id)
        if group.kind.discardsResults {
            precondition(
                group.nextWaiter == nil,
                "discarding task group cannot have a result waiter")
            guard let consumedID = group.takeCompletion(),
                  consumedID == child.id,
                  let outcome = child.outcome else {
                preconditionFailure(
                    "discarding task-group completion was not consumable")
            }

            let isFailure: Bool
            switch outcome {
            case .success:
                isFailure = false
            case .failure, .cancelled:
                isFailure = true
            }
            if isFailure,
               !group.hasDiscardingBodyFailureExit,
               group.firstDiscardingFailure == nil {
                group.firstDiscardingFailure = outcome
                if group.kind.isThrowing {
                    group.hasChildFailureCancellationRequest = true
                    for siblingID in group.childTaskIDs
                    where siblingID != child.id {
                        guard let sibling = records[siblingID],
                              !sibling.state.isCompleted else { continue }
                        requestCancellation(
                            sibling, source: .taskGroupChildFailure)
                    }
                }
            }

            // A discarding group keeps only the first error required for
            // projection. Successful values and later errors must not remain
            // retained by their child records until the lexical scope exits.
            child.outcome = nil
            return
        }
        guard let waiter = group.nextWaiter else { return }
        group.nextWaiter = nil
        guard let childID = group.takeCompletion() else {
            preconditionFailure(
                "task-group waiter resumed without a completed child")
        }
        waiter.resume(returning: childID)
    }

    private func takeCompletedTaskGroupOutcome(
        from group: RuntimeTaskGroupRecord
    ) -> RuntimeTaskOutcome? {
        guard let childID = group.takeCompletion() else { return nil }
        guard let outcome = records[childID]?.outcome else {
            preconditionFailure(
                "completed task-group child \(childID) has no outcome")
        }
        return outcome
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

        let previousPriority = target.effectivePriority
        target.effectivePriority = priority
        target.priorityEscalationHistory[donorID] = priority
        target.evaluationContext?.priority = priority

        // Swift exposes each strict effective-priority increase to every
        // handler active on the target task. Snapshot the dynamic stack so a
        // callback cannot perturb this increase's delivery set. Reverse order
        // matches today's native traversal, but no source guarantee relies on
        // relative handler order.
        let registrations = Array(
            target.priorityEscalationHandlers.reversed())
        for registration in registrations {
            target.priorityEscalationHandlerInvocationCount += 1
            do {
                try registration.invoke(previousPriority, priority)
            } catch {
                // Legal Swift handlers are nonthrowing. Preserve the first
                // interpreter failure defensively and surface it from the
                // target task rather than swallowing it in the donating task.
                if target.priorityEscalationHandlerFailure == nil {
                    target.priorityEscalationHandlerFailure = error
                }
            }
        }

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
