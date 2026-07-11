/// The observable lifecycle of an interpreted `Task`.
///
/// The handle is a core runtime value rather than a SwiftUI stub: cancellation
/// and completion semantics must be identical for every host registry.
public final class RuntimeTaskHandle {
    public enum State: String, Sendable {
        case pending
        case running
        case succeeded
        case cancelled
        case failed
    }

    public private(set) var state: State = .pending
    public private(set) var result: RuntimeValue?
    public private(set) var failureDescription: String?

    private var task: Task<Void, Never>?

    public init() {}

    public var isCancelled: Bool { state == .cancelled }
    public var isCompleted: Bool {
        switch state {
        case .succeeded, .cancelled, .failed: true
        case .pending, .running: false
        }
    }

    public func cancel() {
        guard !isCompleted else { return }
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
        result = value
        state = .succeeded
    }

    func fail(with error: Error) {
        guard state != .cancelled else { return }
        failureDescription = String(describing: error)
        state = .failed
    }

    func wait() async {
        await task?.value
    }
}
