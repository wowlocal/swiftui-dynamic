import Foundation

/// Task-owned lexical frame. It is cheap until the first structured child is
/// declared; only then does it acquire a runtime scope record.
final class RuntimeStructuredScopeFrame {
    let ownerTaskID: RuntimeTaskID?
    var runtimeScope: RuntimeStructuredScopeRecord?
    var cleanups: [RuntimeLexicalCleanupRegistration] = []

    init(ownerTaskID: RuntimeTaskID?) {
        self.ownerTaskID = ownerTaskID
    }
}

/// Cleanup registrations preserve source order so `defer` and structured
/// child teardown unwind together in LIFO order. The evaluator owns deferred
/// syntax bodies by integer slot; the runtime frame owns async-let groups.
enum RuntimeLexicalCleanupRegistration {
    case deferredBody(Int)
    case asyncLet(RuntimeAsyncLetCleanupGroup)
}

/// One `async let` declaration registers one cleanup even when it declares
/// several independent bindings. All children in that declaration are
/// cancelled first and then joined before the next outer cleanup runs.
final class RuntimeAsyncLetCleanupGroup {
    var children: [RuntimeAsyncLetChild] = []
}

/// One structured initializer child. A tuple pattern creates several source
/// bindings that project this same immutable outcome, while scope ownership,
/// cancellation, joining, and record release happen exactly once per child.
final class RuntimeAsyncLetChild {
    let handle: RuntimeTaskHandle
    private(set) var wasExplicitlyAwaited = false

    init(handle: RuntimeTaskHandle) {
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

/// Source `async let` is a value binding, not a public Task handle. This
/// carrier hides the child and selects one projection of its stored outcome.
/// An empty path is the ordinary identifier binding; tuple destructuring adds
/// one zero-based index for each nested tuple level.
final class RuntimeAsyncLetBinding {
    let name: String
    let child: RuntimeAsyncLetChild
    let tupleProjection: [Int]

    init(
        name: String,
        child: RuntimeAsyncLetChild,
        tupleProjection: [Int] = []
    ) {
        self.name = name
        self.child = child
        self.tupleProjection = tupleProjection
    }

    func value(waiter: RuntimeTaskID?) async throws -> RuntimeValue {
        var value = try await child.value(waiter: waiter)
        for index in tupleProjection {
            guard let tuple = value.tupleValue,
                  tuple.values.indices.contains(index) else {
                throw RuntimeError(message:
                    "async let tuple binding '\(name)' does not match its value")
            }
            value = tuple.values[index]
        }
        return value
    }
}
