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

    /// The environment models the body currently being evaluated can see.
    /// A view's own `@Environment` properties are filled before its body runs,
    /// but content that body builds through a NON-View result builder
    /// (`ToolbarContent`, `Commands`, …) is evaluated as a plain instance and
    /// would otherwise never be told what the enclosing environment holds.
    var ambientEnvironmentModels: [String: Instance] = [:]

    /// Key-path environment values visible while the host evaluates a view
    /// body. Source-defined ViewModifiers and non-View builder conformers run
    /// inside that body but have no native host node of their own, so they
    /// inherit this scoped table from the enclosing view.
    var ambientEnvironmentValues: [String: RuntimeValue] = [:]

    /// SwiftUI-style state storage retained by source view identity.
    var viewStateCells: [Interpreter.ViewStateKey: Box] = [:]

    public init() {
        globals = Environment()
    }
}
