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

public enum RuntimeTaskState: String, Sendable {
    case pending
    case running
    case succeeded
    case cancelled
    case failed
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
    var state: RuntimeTaskState = .pending
    var outcome: RuntimeTaskOutcome?
    var failureDescription: String?
    var waiters: Set<RuntimeTaskID> = []
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

    func cancel(_ record: RuntimeTaskRecord) {
        guard !record.state.isCompleted else { return }
        record.outcome = .cancelled
        record.state = .cancelled
        record.evaluationContext = nil
        record.nativeTask?.cancel()
    }

    func release(_ id: RuntimeTaskID) {
        records.removeValue(forKey: id)
    }

    var activeRecordCount: Int { records.count }
}

extension RuntimeTaskState {
    var isCompleted: Bool {
        switch self {
        case .succeeded, .cancelled, .failed: true
        case .pending, .running: false
        }
    }
}
