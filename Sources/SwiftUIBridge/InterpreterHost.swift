import SwiftUI
import SwiftInterpreter

/// Public facade for the demo: source in, rendered root view (or a located
/// error) out. Each render gets a fresh interpreter and registry so edits
/// can't leave stale declarations behind.
public struct InterpreterHost {
    public init() {}

    public func render(source: String, lazyTopLevelGlobals: Bool = false) -> Result<AnyView, RuntimeError> {
        // The demo is INTERACTIVE: debounces and delayed retries run on
        // real wall-clock timers (headless probes drain them instead).
        MainQueueDrain.schedulesRealTimers = true
        HeadlessVerifier.resetBridgeEnvironment()
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        do {
            let last = try interpreter.run(source: source, lazyTopLevelGlobals: lazyTopLevelGlobals)

            // A trailing view expression (e.g. `ContentView()`) is an explicit root.
            if case .host(let any) = last, let view = any as? AnyView {
                return .success(view)
            }
            if case .instance(let instance) = last, instance.symbol.conformsToView {
                return .success(try ViewRegistry.anyView(
                    registry.makeRenderable(instance: instance, interpreter: interpreter)
                ))
            }

            // Otherwise: ContentView > Main > first View struct.
            guard let symbol = interpreter.rootViewSymbol() else {
                return .failure(RuntimeError(message: "no View struct found — declare one conforming to View", line: 1, column: 1))
            }
            guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
                return .failure(RuntimeError(message: "could not instantiate '\(symbol.name)'", line: 1, column: 1))
            }
            return .success(try ViewRegistry.anyView(
                registry.makeRenderable(instance: instance, interpreter: interpreter)
            ))
        } catch let error as RuntimeError {
            return .failure(error)
        } catch {
            return .failure(RuntimeError(message: String(describing: error)))
        }
    }
}
