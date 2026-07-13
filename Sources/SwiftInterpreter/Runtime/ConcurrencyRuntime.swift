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
    case succeeded
    case cancelled
    case failed
}

public enum RuntimeCancellationSource: Hashable, Sendable {
    case taskHandle
    case sessionPolicy
    case hostTask
    case inherited
    case structuredParent
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

/// Mutable lifecycle record owned by the cooperative concurrency runtime.
/// The source-level handle retains this record after session bookkeeping has
/// released it, so completed task values remain readable without leaking them
/// from the runtime's active registry.
final class RuntimeTaskRecord {
    let id: RuntimeTaskID
    let sessionID: RuntimeSessionID
    let kind: RuntimeTaskKind
    let parent: RuntimeTaskID?
    var state: RuntimeTaskState = .pending
    var outcome: RuntimeTaskOutcome?
    var failureDescription: String?
    var cancellation = RuntimeCancellationState()
    var waiters: Set<RuntimeTaskID> = []
    var spawnedTasks: Set<RuntimeTaskID> = []
    var structuredChildren: Set<RuntimeTaskID> = []
    var nativeTask: Task<Void, Never>?
    var evaluationContext: EvaluationTaskContext?

    init(
        id: RuntimeTaskID,
        sessionID: RuntimeSessionID,
        kind: RuntimeTaskKind,
        parent: RuntimeTaskID?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.parent = parent
    }
}

final class CooperativeConcurrencyRuntime {
    private var nextSessionID: UInt64 = 1
    private var nextTaskID: UInt64 = 1
    private var nextEventSequence: UInt64 = 1
    private(set) var records: [RuntimeTaskID: RuntimeTaskRecord] = [:]

    func createSession() -> RuntimeSessionID {
        let id = RuntimeSessionID(rawValue: nextSessionID)
        nextSessionID += 1
        return id
    }

    func createTask(
        sessionID: RuntimeSessionID,
        kind: RuntimeTaskKind,
        parent: RuntimeTaskID?
    ) -> RuntimeTaskRecord {
        let id = RuntimeTaskID(rawValue: nextTaskID)
        nextTaskID += 1
        let record = RuntimeTaskRecord(
            id: id, sessionID: sessionID, kind: kind, parent: parent)
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

    func bind(
        _ context: EvaluationTaskContext, to record: RuntimeTaskRecord
    ) {
        record.evaluationContext = context
    }

    func attach(
        _ nativeTask: Task<Void, Never>, to record: RuntimeTaskRecord
    ) {
        record.nativeTask = nativeTask
        if record.state == .cancelled { nativeTask.cancel() }
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
        record.evaluationContext = nil
    }

    func requestCancellation(
        _ record: RuntimeTaskRecord,
        source: RuntimeCancellationSource
    ) {
        guard !record.state.isCompleted else { return }
        let alreadyRequestedFromSource =
            record.cancellation.sources.contains(source)
        record.cancellation.request(
            from: source, sequence: takeEventSequence())
        record.nativeTask?.cancel()
        if record.state == .pending {
            completeCancellation(record)
        }
        guard !alreadyRequestedFromSource else { return }
        for childID in record.structuredChildren {
            guard let child = records[childID] else { continue }
            requestCancellation(child, source: .structuredParent)
        }
    }

    func completeCancellation(_ record: RuntimeTaskRecord) {
        guard !record.state.isCompleted else { return }
        record.cancellation.observe(sequence: takeEventSequence())
        record.outcome = .cancelled
        record.state = .cancelled
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
        records.removeValue(forKey: id)
    }

    var activeRecordCount: Int { records.count }

    private func takeEventSequence() -> UInt64 {
        defer { nextEventSequence += 1 }
        return nextEventSequence
    }
}

extension RuntimeTaskState {
    var isCompleted: Bool {
        switch self {
        case .succeeded, .cancelled, .failed: true
        case .pending, .running: false
        }
    }
}
