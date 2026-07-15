import SwiftUI
import SwiftInterpreter

/// Public facade for the demo: source in, rendered root view (or a located
/// error) out. Each render gets a fresh interpreter and registry so edits
/// can't leave stale declarations behind.
public struct InterpreterHost {
    private let compilerPreflightMode: CompilerPreflightMode

    /// Compiler checking is explicit because editor and merged-corpus callers
    /// intentionally execute recoverable or platform-substituted source.
    public init(compilerPreflightMode: CompilerPreflightMode = .disabled) {
        self.compilerPreflightMode = compilerPreflightMode
    }

    public func render(source: String, lazyTopLevelGlobals: Bool = false) -> Result<AnyView, RuntimeError> {
        // Reset deterministic probe state. Interactive wall-clock delivery
        // is selected by this host's ViewRegistry, never mutable global state.
        HeadlessVerifier.resetBridgeEnvironment()
        let registry = ViewRegistry()
        do {
            let interpreter: Interpreter
            switch compilerPreflightMode {
            case .disabled:
                interpreter = Interpreter(registry: registry)
            case .diagnosticsOnly, .required:
                interpreter = try Interpreter.withActiveCompilerPreflight(
                    registry: registry,
                    mode: compilerPreflightMode)
            }
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

            // Whole projects should launch through their @main App's
            // composition root so @StateObject models and other stored app
            // state are the actual instances passed by WindowGroup.
            if let declared = interpreter.declaredRootViewExpression() {
                var app: Instance?
                if let appSymbol = declared.app {
                    guard case .instance(let instance) = try interpreter.instantiateRoot(appSymbol) else {
                        return .failure(RuntimeError(message: "could not instantiate '\(appSymbol.name)'"))
                    }
                    app = instance
                }
                let root = try interpreter.evaluateAppRootExpression(declared.expression, app: app)
                if case .instance(let instance) = root, instance.symbol.conformsToView {
                    return .success(try ViewRegistry.anyView(
                        registry.makeRenderable(instance: instance, interpreter: interpreter)
                    ))
                }
                if let view = try? ViewRegistry.anyView(root) {
                    return .success(view)
                }
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
