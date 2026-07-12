/// The observable lifecycle of an interpreted `Task`.
///
/// The handle is a core runtime value rather than a SwiftUI stub: cancellation
/// and completion semantics must be identical for every host registry.
public enum RuntimeTaskOutcome {
    case success(RuntimeValue, successType: String?)
    case failure(RuntimeValue, failureType: String?)
    case cancelled
}

public final class RuntimeTaskHandle {
    public typealias State = RuntimeTaskState

    private let runtime: CooperativeConcurrencyRuntime
    let record: RuntimeTaskRecord

    public var id: RuntimeTaskID { record.id }
    public var kind: RuntimeTaskKind { record.kind }
    public var parent: RuntimeTaskID? { record.parent }
    public var state: State { record.state }
    public var outcome: RuntimeTaskOutcome? { record.outcome }
    public var failureDescription: String? { record.failureDescription }
    var waiterCount: Int { record.waiters.count }

    public convenience init() {
        let runtime = CooperativeConcurrencyRuntime()
        let record = runtime.createTask(kind: .unstructured, parent: nil)
        self.init(runtime: runtime, record: record)
    }

    init(
        runtime: CooperativeConcurrencyRuntime,
        record: RuntimeTaskRecord
    ) {
        self.runtime = runtime
        self.record = record
    }

    public var result: RuntimeValue? {
        guard case .success(let value, _) = record.outcome else { return nil }
        return value
    }

    public var isCancelled: Bool { record.state == .cancelled }
    public var isCompleted: Bool { record.state.isCompleted }

    public func cancel() {
        runtime.cancel(record)
    }

    func attach(_ task: Task<Void, Never>) {
        runtime.attach(task, to: record)
    }

    @discardableResult
    func begin() -> Bool {
        runtime.begin(record)
    }

    func succeed(with value: RuntimeValue) {
        runtime.succeed(record, with: value)
    }

    func fail(with error: Error) {
        runtime.fail(record, with: error)
    }

    func wait() async {
        await record.nativeTask?.value
    }

    func waitForOutcome(
        waiter: RuntimeTaskID? = nil
    ) async -> RuntimeTaskOutcome {
        if let waiter { record.waiters.insert(waiter) }
        defer {
            if let waiter { record.waiters.remove(waiter) }
        }
        await record.nativeTask?.value
        return record.outcome ?? .failure(
            .native("task completed without an outcome"),
            failureType: "RuntimeTaskInvariant")
    }
}
