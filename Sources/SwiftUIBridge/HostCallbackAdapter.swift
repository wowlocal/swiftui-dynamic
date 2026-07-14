import SwiftInterpreter

/// Re-enters interpreted code from a synchronous framework callback.
///
/// SwiftUI actions are synchronous, so mutations made by the source closure
/// must be visible before this call returns. The interpreter still creates a
/// logical host-callback task/session, allowing source `Task` values created by
/// the action to use the canonical concurrency runtime instead of the legacy
/// inline compatibility path.
struct InterpretedHostCallback {
    let closure: ClosureValue
    let context: EvalContext
    let diagnosticContext: String

    func call(arguments: [RuntimeValue] = []) {
        do {
            _ = try context.callHostCallback(closure, arguments: arguments)
        } catch let error as RuntimeError {
            RenderDiagnostics.record(error, in: diagnosticContext)
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: String(describing: error)),
                in: diagnosticContext)
        }
    }
}
