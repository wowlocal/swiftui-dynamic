import Foundation

/// Task-owned lexical frame. It is cheap until the first structured child is
/// declared; only then does it acquire a runtime scope record.
final class RuntimeStructuredScopeFrame {
    let ownerTaskID: RuntimeTaskID?
    var runtimeScope: RuntimeStructuredScopeRecord?
    var asyncLetBindings: [RuntimeAsyncLetBinding] = []

    init(ownerTaskID: RuntimeTaskID?) {
        self.ownerTaskID = ownerTaskID
    }
}

/// Source `async let` is a value binding, not a public Task handle. This
/// carrier keeps the child handle internal while making explicit reads and
/// implicit scope-exit joins use the same stored outcome.
final class RuntimeAsyncLetBinding {
    let name: String
    let handle: RuntimeTaskHandle
    private(set) var wasExplicitlyAwaited = false

    init(name: String, handle: RuntimeTaskHandle) {
        self.name = name
        self.handle = handle
    }

    func value(waiter: RuntimeTaskID?) async throws -> RuntimeValue {
        wasExplicitlyAwaited = true
        switch await handle.waitForOutcome(waiter: waiter) {
        case .success(let value, _):
            return value
        case .failure(let value, _):
            throw InterpretedThrow(value: value)
        case .cancelled:
            throw CancellationError()
        }
    }

    func cancelIfUnconsumedAtScopeExit() {
        guard !wasExplicitlyAwaited, !handle.isCompleted else { return }
        handle.cancel(source: .structuredScopeExit)
    }

    func waitForScopeExit(waiter: RuntimeTaskID?) async {
        _ = await handle.waitForOutcome(waiter: waiter)
    }
}
