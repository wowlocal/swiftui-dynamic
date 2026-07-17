/// MainActor-confined root of mutable language storage.
///
/// This is deliberately not a worker-safe heap yet. Making ownership
/// explicit prevents immutable program metadata and task-local evaluator
/// state from being conflated with storage that must remain confined until a
/// later M9 synchronization/confinement slice.
@MainActor
public final class RuntimeHeap {
    public let globals: Environment

    /// Host-framework stand-ins shared by every view in one interpreter.
    var synthesizedEnvironmentModels: [String: Instance] = [:]

    /// SwiftUI-style state storage retained by source view identity.
    var viewStateCells: [Interpreter.ViewStateKey: Box] = [:]

    public init() {
        globals = Environment()
    }
}
