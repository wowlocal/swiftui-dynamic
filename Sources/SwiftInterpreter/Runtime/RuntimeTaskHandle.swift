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
    public enum State: String, Sendable {
        case pending
        case running
        case succeeded
        case cancelled
        case failed
    }

    public private(set) var state: State = .pending
    public private(set) var outcome: RuntimeTaskOutcome?
    public private(set) var failureDescription: String?

    private var task: Task<Void, Never>?

    public init() {}

    public var result: RuntimeValue? {
        guard case .success(let value, _) = outcome else { return nil }
        return value
    }

    public var isCancelled: Bool { state == .cancelled }
    public var isCompleted: Bool {
        switch state {
        case .succeeded, .cancelled, .failed: true
        case .pending, .running: false
        }
    }

    public func cancel() {
        guard !isCompleted else { return }
        outcome = .cancelled
        state = .cancelled
        task?.cancel()
    }

    func attach(_ task: Task<Void, Never>) {
        self.task = task
        if state == .cancelled { task.cancel() }
    }

    @discardableResult
    func begin() -> Bool {
        guard state == .pending else { return false }
        state = .running
        return true
    }

    func succeed(with value: RuntimeValue) {
        guard state != .cancelled else { return }
        outcome = .success(
            value, successType: HostRuntimeTypeSystem.typeName(of: value))
        state = .succeeded
    }

    func fail(with error: Error) {
        guard state != .cancelled else { return }
        failureDescription = String(describing: error)
        if let thrown = error as? InterpretedThrow {
            outcome = .failure(
                thrown.value,
                failureType: HostRuntimeTypeSystem.typeName(of: thrown.value))
        } else {
            let value = RuntimeValue.native(String(describing: error))
            outcome = .failure(
                value, failureType: String(describing: type(of: error)))
        }
        state = .failed
    }

    func wait() async {
        await task?.value
    }

    func waitForOutcome() async -> RuntimeTaskOutcome {
        await wait()
        return outcome ?? .failure(
            .native("task completed without an outcome"),
            failureType: "RuntimeTaskInvariant")
    }
}
