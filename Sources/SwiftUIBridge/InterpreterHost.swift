import SwiftInterpreter
import SwiftUI

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

    public func render(
        source: String,
        lazyTopLevelGlobals: Bool = false
    ) -> Result<AnyView, RuntimeError> {
        render(
            source: source,
            compilerSources: nil,
            buildTarget: nil,
            lazyTopLevelGlobals: lazyTopLevelGlobals
        )
    }

    /// Render one explicitly selected build target. Compiler checking sees the
    /// manifest's original files and imports, while runtime interpretation uses
    /// the deterministic projection derived from those exact same inputs.
    public func render(
        project: ProjectBuildManifest,
        lazyTopLevelGlobals: Bool = true
    ) -> Result<AnyView, RuntimeError> {
        BundleBox.projectResourceRoot = project.projectRoot
        return render(
            source: ProjectMaterial.mergedSource(for: project),
            compilerSources: project.sources,
            buildTarget: project.buildTarget,
            lazyTopLevelGlobals: lazyTopLevelGlobals
        )
    }

    private func render(
        source: String,
        compilerSources explicitCompilerSources: [CompilerPreflightSource]?,
        buildTarget: CompilerPreflightBuildTarget?,
        lazyTopLevelGlobals: Bool
    ) -> Result<AnyView, RuntimeError> {
        // Reset deterministic probe state. Interactive wall-clock delivery
        // is selected by this host's ViewRegistry, never mutable global state.
        HeadlessVerifier.resetBridgeEnvironment()
        let registry = ViewRegistry()
        do {
            let interpreter: Interpreter
            if let buildTarget {
                switch compilerPreflightMode {
                case .disabled:
                    interpreter = Interpreter(
                        registry: registry,
                        buildConfiguration: InterpreterBuildConfiguration(
                            buildTarget: buildTarget)
                    )
                case .diagnosticsOnly, .required:
                    interpreter = try Interpreter.withActiveCompilerPreflight(
                        registry: registry,
                        buildTarget: buildTarget,
                        mode: compilerPreflightMode
                    )
                }
            } else {
                switch compilerPreflightMode {
                case .disabled:
                    interpreter = Interpreter(registry: registry)
                case .diagnosticsOnly, .required:
                    interpreter = try Interpreter.withActiveCompilerPreflight(
                        registry: registry,
                        mode: compilerPreflightMode
                    )
                }
            }
            let compilerSources: [CompilerPreflightSource]?
            switch compilerPreflightMode {
            case .disabled:
                compilerSources = nil
            case .diagnosticsOnly, .required:
                compilerSources = explicitCompilerSources
                    ?? ProjectMaterial.compilerPreflightSources(from: source)
            }
            let last = try interpreter.run(
                source: source,
                lazyTopLevelGlobals: lazyTopLevelGlobals,
                compilerPreflightSources: compilerSources
            )

            // A trailing view expression (e.g. `ContentView()`) is an explicit root.
            if case let .host(any) = last, let view = any as? AnyView {
                return .success(view)
            }
            if case let .instance(instance) = last, instance.symbol.conformsToView {
                return try .success(ViewRegistry.anyView(
                    registry.makeRenderable(instance: instance, interpreter: interpreter)
                ))
            }

            // Whole projects should launch through their @main App's
            // composition root so @StateObject models and other stored app
            // state are the actual instances passed by WindowGroup.
            if let declared = interpreter.declaredRootViewExpression() {
                var app: Instance?
                if let appSymbol = declared.app {
                    guard case let .instance(instance) = try interpreter.instantiateRoot(appSymbol) else {
                        return .failure(RuntimeError(message: "could not instantiate '\(appSymbol.name)'"))
                    }
                    app = instance
                }
                let root = try interpreter.evaluateAppRootExpression(declared.expression, app: app)
                if case let .instance(instance) = root, instance.symbol.conformsToView {
                    return try .success(ViewRegistry.anyView(
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
            guard case let .instance(instance) = try interpreter.instantiateRoot(symbol) else {
                return .failure(RuntimeError(message: "could not instantiate '\(symbol.name)'", line: 1, column: 1))
            }
            return try .success(ViewRegistry.anyView(
                registry.makeRenderable(instance: instance, interpreter: interpreter)
            ))
        } catch let error as RuntimeError {
            return .failure(error)
        } catch {
            return .failure(RuntimeError(message: String(describing: error)))
        }
    }
}
