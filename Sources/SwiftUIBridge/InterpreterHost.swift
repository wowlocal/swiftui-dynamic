import SwiftInterpreter
import SwiftUI

/// One rendered view and the exact interpreter that owns its source state and
/// asynchronous runtime activity.
///
/// Keeping the pair as a value lets independent hosts observe their own work
/// without consulting `InterpreterHost.lastInterpreter`, whose process-global
/// identity is retained only as a compatibility probe.
public struct InterpreterRenderSession {
    public let view: AnyView
    public let interpreter: Interpreter
}

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

    /// The interpreter behind the most recent render — probe/test surface
    /// (drive the live model store or read symbols of a hosted render).
    public private(set) static var lastInterpreter: Interpreter?

    public func render(
        source: String,
        lazyTopLevelGlobals: Bool = false
    ) -> Result<AnyView, RuntimeError> {
        renderSessionCore(
            source: source,
            compilerSources: nil,
            buildTarget: nil,
            buildConfiguration: nil,
            projectResourceRoot: nil,
            lazyTopLevelGlobals: lazyTopLevelGlobals
        ).map(\.view)
    }

    /// Render a merged source projection with one immutable bundled-resource
    /// root. Source-only renders intentionally receive no project resources.
    public func render(
        source: String,
        projectResourceRoot: String,
        lazyTopLevelGlobals: Bool = false
    ) -> Result<AnyView, RuntimeError> {
        renderSessionCore(
            source: source,
            compilerSources: nil,
            buildTarget: nil,
            buildConfiguration: nil,
            projectResourceRoot: projectResourceRoot,
            lazyTopLevelGlobals: lazyTopLevelGlobals
        ).map(\.view)
    }

    /// Render merged source against one immutable conditional-compilation
    /// identity. Compiler-checked callers must instead provide a project
    /// manifest so native checking and interpretation cannot disagree about
    /// their selected target.
    public func render(
        source: String,
        buildConfiguration: InterpreterBuildConfiguration,
        lazyTopLevelGlobals: Bool = false
    ) -> Result<AnyView, RuntimeError> {
        renderSessionCore(
            source: source,
            compilerSources: nil,
            buildTarget: nil,
            buildConfiguration: buildConfiguration,
            projectResourceRoot: nil,
            lazyTopLevelGlobals: lazyTopLevelGlobals
        ).map(\.view)
    }

    /// Render merged source with both of its immutable execution inputs when
    /// no compiler manifest exists: conditional-compilation identity and the
    /// project resource root are independent properties of the same render.
    public func render(
        source: String,
        buildConfiguration: InterpreterBuildConfiguration,
        projectResourceRoot: String,
        lazyTopLevelGlobals: Bool = false
    ) -> Result<AnyView, RuntimeError> {
        renderSessionCore(
            source: source,
            compilerSources: nil,
            buildTarget: nil,
            buildConfiguration: buildConfiguration,
            projectResourceRoot: projectResourceRoot,
            lazyTopLevelGlobals: lazyTopLevelGlobals
        ).map(\.view)
    }

    /// Render one explicitly selected build target. Compiler checking sees the
    /// manifest's original files and imports, while runtime interpretation uses
    /// the deterministic projection derived from those exact same inputs.
    public func render(
        project: ProjectBuildManifest,
        lazyTopLevelGlobals: Bool = true
    ) -> Result<AnyView, RuntimeError> {
        renderSessionCore(
            source: ProjectMaterial.mergedSource(for: project),
            compilerSources: project.sources,
            buildTarget: project.buildTarget,
            buildConfiguration: nil,
            projectResourceRoot: project.projectRoot,
            lazyTopLevelGlobals: lazyTopLevelGlobals
        ).map(\.view)
    }

    /// Render source while retaining the exact interpreter that owns the
    /// resulting view. Optional execution inputs cover every source-based
    /// `render` overload through one property-driven entry point.
    public func renderSession(
        source: String,
        buildConfiguration: InterpreterBuildConfiguration? = nil,
        projectResourceRoot: String? = nil,
        lazyTopLevelGlobals: Bool = false
    ) -> Result<InterpreterRenderSession, RuntimeError> {
        renderSessionCore(
            source: source,
            compilerSources: nil,
            buildTarget: nil,
            buildConfiguration: buildConfiguration,
            projectResourceRoot: projectResourceRoot,
            lazyTopLevelGlobals: lazyTopLevelGlobals)
    }

    /// Target-aware counterpart to `render(project:)`, retaining the session
    /// while native preflight and interpretation consume the same manifest.
    public func renderSession(
        project: ProjectBuildManifest,
        lazyTopLevelGlobals: Bool = true
    ) -> Result<InterpreterRenderSession, RuntimeError> {
        renderSessionCore(
            source: ProjectMaterial.mergedSource(for: project),
            compilerSources: project.sources,
            buildTarget: project.buildTarget,
            buildConfiguration: nil,
            projectResourceRoot: project.projectRoot,
            lazyTopLevelGlobals: lazyTopLevelGlobals)
    }

    private func renderSessionCore(
        source: String,
        compilerSources explicitCompilerSources: [CompilerPreflightSource]?,
        buildTarget: CompilerPreflightBuildTarget?,
        buildConfiguration explicitBuildConfiguration:
            InterpreterBuildConfiguration?,
        projectResourceRoot: String?,
        lazyTopLevelGlobals: Bool
    ) -> Result<InterpreterRenderSession, RuntimeError> {
        // Reset deterministic probe state. Interactive wall-clock delivery
        // is selected by this host's ViewRegistry, never mutable global state.
        HeadlessVerifier.resetBridgeEnvironment()
        let registry = ViewRegistry(
            projectResourceRoot: projectResourceRoot)
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
                    interpreter = Interpreter(
                        registry: registry,
                        buildConfiguration: explicitBuildConfiguration)
                case .diagnosticsOnly, .required:
                    guard explicitBuildConfiguration == nil else {
                        return .failure(RuntimeError(message:
                            "compiler preflight requires a target-aware "
                                + "project manifest when an explicit build "
                                + "configuration is supplied"))
                    }
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
            Self.lastInterpreter = interpreter
            let last = try interpreter.run(
                source: source,
                lazyTopLevelGlobals: lazyTopLevelGlobals,
                compilerPreflightSources: compilerSources
            )

            // A trailing view expression is an explicit root. Generated
            // constructors deliberately retain concrete SDK View values until
            // this rendering boundary, so recognize the registry's semantic
            // property instead of requiring prior AnyView erasure.
            if registry.isViewValue(last) {
                return .success(InterpreterRenderSession(
                    view: try ViewRegistry.anyView(last),
                    interpreter: interpreter))
            }
            if case let .instance(instance) = last, instance.symbol.conformsToView {
                return try .success(InterpreterRenderSession(
                    view: ViewRegistry.anyView(registry.makeRenderable(
                        instance: instance, interpreter: interpreter)),
                    interpreter: interpreter))
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
                    return try .success(InterpreterRenderSession(
                        view: ViewRegistry.anyView(registry.makeRenderable(
                            instance: instance, interpreter: interpreter)),
                        interpreter: interpreter))
                }
                if let view = try? ViewRegistry.anyView(root) {
                    return .success(InterpreterRenderSession(
                        view: view, interpreter: interpreter))
                }
            }

            // Otherwise: ContentView > Main > first View struct.
            guard let symbol = interpreter.rootViewSymbol() else {
                return .failure(RuntimeError(message: "no View struct found — declare one conforming to View", line: 1, column: 1))
            }
            guard case let .instance(instance) = try interpreter.instantiateRoot(symbol) else {
                return .failure(RuntimeError(message: "could not instantiate '\(symbol.name)'", line: 1, column: 1))
            }
            return try .success(InterpreterRenderSession(
                view: ViewRegistry.anyView(registry.makeRenderable(
                    instance: instance, interpreter: interpreter)),
                interpreter: interpreter))
        } catch let error as RuntimeError {
            return .failure(error)
        } catch {
            return .failure(RuntimeError(message: String(describing: error)))
        }
    }
}
