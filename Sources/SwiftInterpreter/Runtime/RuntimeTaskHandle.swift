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

    private let runtime: CooperativeConcurrencyRuntime
    let record: RuntimeTaskRecord

    public var id: RuntimeTaskID { record.id }
    public var sessionID: RuntimeSessionID { record.sessionID }
    public var kind: RuntimeTaskKind { record.kind }
    public var parent: RuntimeTaskID? { record.parent }
    public var state: State { record.state }
    public var outcome: RuntimeTaskOutcome? { record.outcome }
    public var failureDescription: String? { record.failureDescription }
    var waiterCount: Int { record.waiters.count }

    public convenience init() {
        let runtime = CooperativeConcurrencyRuntime()
        let record = runtime.createTask(
            sessionID: runtime.createSession(),
            kind: .unstructured,
            parent: nil)
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

    public var resultValue: RuntimeResultValue? {
        record.outcome.map(RuntimeResultValue.init(taskOutcome:))
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
