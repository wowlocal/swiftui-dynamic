import SwiftInterpreter

/// The reusable semantic adapter behind generated SwiftUI async modifiers.
///
/// BridgeGen owns the ordinary `.task`, `.task(id:)`, and `.refreshable` API
/// surface. Real SwiftUI owns view identity and the outer task's lifecycle;
/// this adapter only enters the interpreter's canonical `.swiftUITask`
/// runtime and reports non-cancellation failures at the render boundary.
struct InterpretedSwiftUITaskCallback {
    let closure: ClosureValue
    let context: EvalContext
    let diagnosticContext: String

    func call(arguments: [RuntimeValue] = []) async {
        do {
            _ = try await context.callSwiftUITask(
                closure, arguments: arguments)
        } catch is CancellationError {
            // Disappearance and `.task(id:)` replacement normally cancel the
            // view task. Native SwiftUI does not surface that as a render error.
        } catch let error as RuntimeError {
            RenderDiagnostics.record(error, in: diagnosticContext)
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: String(describing: error)),
                in: diagnosticContext)
        }
    }
}
