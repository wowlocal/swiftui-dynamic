import Foundation
import SwiftSyntax

/// Per-interpreter conditional-compilation identity. Target-aware project
/// callers derive this from the same build target used by compiler preflight;
/// legacy callers retain the historical iOS + DEBUG canvas.
public struct InterpreterBuildConfiguration: Sendable, Equatable {
    public let platformName: String
    public let targetEnvironment: String?
    public let architecture: String?
    public let activeCompilationConditions: Set<String>
    public let swiftLanguageVersion: CompilerPreflightSwiftLanguageVersion
    public let swiftConditionalCompilationVersion:
        CompilerPreflightVersion?
    public let compilerVersion: CompilerPreflightVersion?
    public let defaultIsolation: CompilerPreflightDefaultIsolation
    public let appleSDK: CompilerPreflightAppleSDK?
    /// `nil` preserves the legacy platform heuristic. A target manifest always
    /// supplies a complete set (which may be empty), making `canImport` exact.
    public let authoritativeImportableModules: Set<String>?
    public let authoritativeVersionedImportQueries: [String: Bool]?
    /// `nil` preserves legacy best-effort behavior. Target-aware construction
    /// always supplies a dictionary (possibly empty), so unrecorded
    /// compiler-owned predicates can be rejected before execution.
    public let authoritativeConditionalCompilationQueries: [String: Bool]?

    public init(
        platformName: String = "iOS",
        targetEnvironment: String? = nil,
        architecture: String? = nil,
        activeCompilationConditions: Set<String> = ["DEBUG"],
        swiftLanguageVersion: CompilerPreflightSwiftLanguageVersion = .swift6,
        swiftConditionalCompilationVersion: CompilerPreflightVersion? = nil,
        compilerVersion: CompilerPreflightVersion? = nil,
        defaultIsolation: CompilerPreflightDefaultIsolation = .nonisolated,
        appleSDK: CompilerPreflightAppleSDK? = nil,
        authoritativeImportableModules: Set<String>? = nil,
        authoritativeVersionedImportQueries: [String: Bool]? = nil,
        authoritativeConditionalCompilationQueries: [String: Bool]? = nil
    ) {
        self.platformName = platformName
        self.targetEnvironment = targetEnvironment
        self.architecture = architecture
        self.activeCompilationConditions = activeCompilationConditions
        self.swiftLanguageVersion = swiftLanguageVersion
        self.swiftConditionalCompilationVersion =
            swiftConditionalCompilationVersion
        self.compilerVersion = compilerVersion
        self.defaultIsolation = defaultIsolation
        self.appleSDK = appleSDK
        self.authoritativeImportableModules = authoritativeImportableModules
        self.authoritativeVersionedImportQueries =
            authoritativeVersionedImportQueries
        self.authoritativeConditionalCompilationQueries =
            authoritativeConditionalCompilationQueries
    }

    public init(buildTarget: CompilerPreflightBuildTarget) {
        self.init(
            platformName: buildTarget.sdk.platformName,
            targetEnvironment: buildTarget.sdk.targetEnvironment,
            architecture: buildTarget.architecture,
            activeCompilationConditions:
                Set(buildTarget.activeCompilationConditions),
            swiftLanguageVersion: buildTarget.swiftLanguageVersion,
            swiftConditionalCompilationVersion:
                buildTarget.swiftConditionalCompilationVersion,
            compilerVersion: buildTarget.compilerVersion,
            defaultIsolation: buildTarget.defaultIsolation,
            appleSDK: buildTarget.sdk,
            authoritativeImportableModules:
                Set(buildTarget.importableModules),
            authoritativeVersionedImportQueries: Dictionary(
                uniqueKeysWithValues: buildTarget.versionedImportQueries.map {
                    ($0.identity, $0.isImportable)
                }),
            authoritativeConditionalCompilationQueries: Dictionary(
                uniqueKeysWithValues:
                    buildTarget.conditionalCompilationQueries.map {
                        ($0.identity, $0.isActive)
                    }))
    }

    func canImport(_ moduleName: String) -> Bool {
        if let authoritativeImportableModules {
            return authoritativeImportableModules.contains(moduleName)
        }
        switch appleSDK {
        case .macOS:
            return !["UIKit", "WatchKit"].contains(moduleName)
        case .watchOS, .watchOSSimulator:
            return !["AppKit", "Cocoa", "UIKit"].contains(moduleName)
        case .iOS, .iOSSimulator, .macCatalyst, .tvOS, .tvOSSimulator,
             .visionOS, .visionOSSimulator:
            return !["AppKit", "Cocoa", "WatchKit"].contains(moduleName)
        case nil:
            if platformName == "macOS" {
                return !["UIKit", "WatchKit"].contains(moduleName)
            }
            return !["AppKit", "Cocoa"].contains(moduleName)
        }
    }

    func canImport(
        _ moduleName: String,
        versionKind: String,
        version: String
    ) -> Bool {
        guard let authoritativeVersionedImportQueries else {
            return canImport(moduleName)
        }
        let identity = moduleName + "\u{0}" + versionKind + "\u{0}" + version
        return authoritativeVersionedImportQueries[identity] ?? false
    }

    func conditionalCompilationQuery(
        predicate: String,
        argument: String
    ) -> Bool? {
        authoritativeConditionalCompilationQueries?[
            predicate + "\u{0}" + argument
        ]
    }
}

/// The public facade: parse → fold operators → collect declarations → evaluate.
///
/// A tree-walking interpreter over SwiftSyntax ASTs. It implements no
/// framework functionality itself; anything beyond core language semantics is
/// delegated to a `HostRegistry` (the SwiftUI bridge, or a trace registry in
/// tests).
public final class Interpreter {
    public let globals = Environment()
    let concurrencyRuntime: CooperativeConcurrencyRuntime
    public let runtimeClock: any RuntimeClock
    public var registry: HostRegistry?
    public let compilerPreflight: SwiftCompilerPreflight?
    public let compilerPreflightMode: CompilerPreflightMode
    public let buildConfiguration: InterpreterBuildConfiguration
    public internal(set) var lastCompilerPreflightResult:
        CompilerPreflightResult?
    /// Struct symbols in declaration order (used to pick the root View).
    public internal(set) var structSymbols: [StructSymbol] = []
    var enumSymbols: [String: EnumSymbol] = [:]
    /// Env-object models constructed as fresh-store stand-ins (one per type,
    /// so every view reading the type sees the same instance).
    var synthesizedEnvironmentModels: [String: Instance] = [:]
    /// Interpreted `extension View { … }` / `extension String { … }` members,
    /// keyed by the extended host type's name.
    var hostExtensionSymbols: [String: StructSymbol] = [:]
    var assumesCompiledImports = false
    /// Legacy default captured by interpreters constructed without an
    /// explicit `InterpreterBuildConfiguration`. Target-manifest callers use
    /// immutable per-instance build identity instead.
    public static var interpretsAsPlatform = "iOS"
    /// When the PROGRAM shadows `Date.now` (`extension Date { static var
    /// now }` — the frozen-clock harness), bridge coercions that must
    /// resolve a bare `.now` marker in Date positions consult this instead
    /// of the wall clock, honoring the same-module shadowing rule at every
    /// boundary. Set per run by ProgramEvaluator; nil = wall clock.
    public static var ambientDateNowProvider: (() -> Date)?
    /// RNG_TRACE diagnostics only.
    public static var rngDrawCount = 0
    /// Number of large finite loops prepared by this interpreter instance.
    /// Kept as a white-box metric so parity tests can prove that optimized
    /// semantics, rather than the tree-walking fallback, were exercised.
    private(set) var preparedFiniteLoopPlanCount = 0
    var coreFunctionIntrinsics: [
        ObjectIdentifier: (function: HostFunction, intrinsic: CoreFunctionIntrinsic)
    ] = [:]

    func recordPreparedFiniteLoopPlan() {
        preparedFiniteLoopPlanCount += 1
    }

    func registerCoreFunctionIntrinsic(
        _ intrinsic: CoreFunctionIntrinsic,
        for function: HostFunction
    ) {
        coreFunctionIntrinsics[ObjectIdentifier(function)] = (function, intrinsic)
    }

    func coreFunctionIntrinsic(for function: HostFunction) -> CoreFunctionIntrinsic? {
        guard let registration = coreFunctionIntrinsics[ObjectIdentifier(function)],
              registration.function === function else { return nil }
        return registration.intrinsic
    }

    /// Interpreted protocol declarations' inheritance (`protocol
    /// ConnectedView: View`) — conformance through a protocol must count as
    /// View-ness for the render pipeline.
    var protocolInheritance: [String: [String]] = [:]

    func protocolReachesView(_ name: String, seen: inout Set<String>) -> Bool {
        guard seen.insert(name).inserted else { return false }
        guard let inherited = protocolInheritance[name] else { return false }
        if inherited.contains("View") { return true }
        return inherited.contains { protocolReachesView($0, seen: &seen) }
    }

    /// Transitive protocol conformance (`AsyncAction: Action` reaches
    /// `Action`) — the `is`/`as?` machinery walks declared inheritance.
    func protocolReaches(_ name: String, target: String, seen: inout Set<String>) -> Bool {
        if name == target { return true }
        guard seen.insert(name).inserted else { return false }
        guard let inherited = protocolInheritance[name] else { return false }
        return inherited.contains { protocolReaches($0, target: target, seen: &seen) }
    }

    func resolveTransitiveViewConformance() {
        guard !protocolInheritance.isEmpty else { return }
        for symbol in structSymbols where !symbol.conformsToView {
            var seen = Set<String>()
            if symbol.conformances.contains(where: { protocolReachesView($0, seen: &seen) }) {
                symbol.conformsToView = true
            }
        }
    }

    /// A symbol's conformances CLOSED over protocol refinement — extension
    /// defaults on `WebRepository` serve a type declared only as
    /// `CountriesWebRepository: WebRepository` (member lookup order stays
    /// declaration-first: direct conformances precede inherited ones).
    func transitiveConformances(of symbol: StructSymbol) -> [String] {
        var out: [String] = []
        var queue = symbol.conformances
        var seen = Set<String>()
        while !queue.isEmpty {
            let name = queue.removeFirst()
            guard seen.insert(name).inserted else { continue }
            out.append(name)
            queue.append(contentsOf: protocolInheritance[name] ?? [])
        }
        return out
    }

    /// The symbol's body accessor: its OWN computed property, or a
    /// protocol-extension default (SwiftUIFlux's ConnectedView serves `body`
    /// from `extension ConnectedView`).
    func bodyProperty(of symbol: StructSymbol) -> ComputedProperty? {
        if let own = symbol.computedProperties["body"] { return own }
        for conformance in transitiveConformances(of: symbol) {
            if let ext = hostExtensionSymbols[conformance],
               let body = ext.computedProperties["body"] {
                return body
            }
        }
        return nil
    }

    /// Demand signal for the generated-members tier: every (dynamic type,
    /// member) pair the absorb terminus swallowed on a host native. Feeding
    /// this histogram back into BridgeGen's member sweep is how the generated
    /// surface grows — fill the biggest absorber, regenerate, re-measure.
    public private(set) var absorbedHostMembers: [String: Int] = [:]

    /// Cross-run census (INTERP_ABSORB_CENSUS=1): aggregates across every
    /// interpreter instance a harness creates — the DEMAND CURVE of the
    /// whole corpus, not one scenario.
    public static var absorbCensus: [String: Int] = [:]
    static let censusEnabled = ProcessInfo.processInfo.environment["INTERP_ABSORB_CENSUS"] != nil

    func recordAbsorbedHostMember(type typeName: String, member: String) {
        let key = "\(typeName).\(member)"
        if Self.censusEnabled {
            Self.absorbCensus[key, default: 0] += 1
        }
        if absorbedHostMembers[key] == nil, absorbedHostMembers.count >= 512 { return }
        absorbedHostMembers[key, default: 0] += 1
    }

    var locationConverter: SourceLocationConverter?
    private lazy var synchronousEvaluationTaskContext = EvaluationTaskContext(
        id: 0, interpreter: self)
    private var nextEvaluationTaskContextID: UInt64 = 1

    var evaluationTaskContext: EvaluationTaskContext {
        if let current = EvaluationTaskContext.current,
           current.interpreter === self {
            return current
        }
        return synchronousEvaluationTaskContext
    }

    func makeEvaluationTaskContext(
        runtimeTaskID: RuntimeTaskID? = nil,
        runtimeSessionID: RuntimeSessionID? = nil,
        isAsyncSession: Bool = false,
        priority: RuntimeTaskPriority = .medium,
        executor: RuntimeExecutorKind = .mainActor,
        taskLocals: RuntimeTaskLocalStorage = RuntimeTaskLocalStorage()
    ) -> EvaluationTaskContext {
        let id = nextEvaluationTaskContextID
        nextEvaluationTaskContextID += 1
        return EvaluationTaskContext(
            id: id,
            runtimeTaskID: runtimeTaskID,
            runtimeSessionID: runtimeSessionID,
            isAsyncSession: isAsyncSession,
            priority: priority,
            executor: executor,
            taskLocals: taskLocals,
            interpreter: self)
    }

    /// White-box identity used by concurrency ownership and host re-entry
    /// tests. Runtime task identity itself is introduced in M2.
    var currentEvaluationTaskContextID: UInt64 { evaluationTaskContext.id }
    var steps: Int {
        get { evaluationTaskContext.steps }
        set { evaluationTaskContext.steps = newValue }
    }
    /// Guards against `while true {}` freezing the UI: evaluation is main-actor.
    let stepBudget = 100_000
    /// Guards against runaway interpreted recursion overflowing the NATIVE
    /// stack (each interpreted call is ~10 Swift frames) before the step
    /// budget can trip. Fatal — never catchable by interpreted code.
    var callDepth: Int {
        get { evaluationTaskContext.callDepth }
        set { evaluationTaskContext.callDepth = newValue }
    }
    let callDepthLimit = 200
    var evaluationDepth: Int {
        get { evaluationTaskContext.evaluationDepth }
        set { evaluationTaskContext.evaluationDepth = newValue }
    }
    /// Stack bounds are thread-stable for this main-actor interpreter. Cache
    /// them once instead of asking pthread for the same values at every
    /// recursion probe on the expression hot path.
    struct EvaluationStackBounds {
        let lowerBound: UInt
        let size: UInt
        let safetyHeadroom: UInt
    }
    var evaluationStackBounds: EvaluationStackBounds?
    var resolveAnnotatedDepth: Int {
        get { evaluationTaskContext.resolveAnnotatedDepth }
        set { evaluationTaskContext.resolveAnnotatedDepth = newValue }
    }
    var synchronousTaskDepth: Int {
        get { evaluationTaskContext.synchronousTaskDepth }
        set { evaluationTaskContext.synchronousTaskDepth = newValue }
    }
    var scheduledTasks: [RuntimeTaskHandle] = []
    /// Collision-free bindings used while lowering awaited subexpressions
    /// into the established synchronous expression machinery.
    var asyncTemporarySerial: Int {
        get { evaluationTaskContext.asyncTemporarySerial }
        set { evaluationTaskContext.asyncTemporarySerial = newValue }
    }
    let scheduledTaskLimit = 1_024
    /// Host-extension method frames currently executing (recursion guard:
    /// re-entrant same-name dispatch prefers the registry gateway).
    var activeExtensionFrames: Set<ExtensionFrame> {
        get { evaluationTaskContext.activeExtensionFrames }
        set { evaluationTaskContext.activeExtensionFrames = newValue }
    }
    /// DI-container resolution (`@Dependency(\.pool)`): instances are SHARED
    /// per type, and circular graphs break with an absorbing marker (real
    /// containers resolve cycles lazily).
    var dependencyCache: [String: RuntimeValue] = [:]
    var dependencyInFlight: Set<String> {
        get { evaluationTaskContext.dependencyInFlight }
        set { evaluationTaskContext.dependencyInFlight = newValue }
    }
    /// Initializer bodies currently executing — self-delegation must not
    /// re-enter the same init (extension convenience → memberwise).
    var activeInitializers: Set<SyntaxIdentifier> {
        get { evaluationTaskContext.activeInitializers }
        set { evaluationTaskContext.activeInitializers = newValue }
    }
    /// Instances whose declared `init` body is currently executing: self-
    /// stores inside init are DIRECT (compiled semantics — willSet/didSet
    /// never fire during initialization).
    var initializingInstances: Set<ObjectIdentifier> {
        get { evaluationTaskContext.initializingInstances }
        set { evaluationTaskContext.initializingInstances = newValue }
    }
    /// Function bodies currently executing — overload dispatch excludes the
    /// running declaration (`send(_:) -> StoreTask` delegating to
    /// `send(_:) -> Task?`, identical shapes, return-type disambiguated).
    var activeFunctionBodies: Set<SyntaxIdentifier> {
        get { evaluationTaskContext.activeFunctionBodies }
        set { evaluationTaskContext.activeFunctionBodies = newValue }
    }
    /// Instance pairs mid-comparison in synthesized member-wise equality —
    /// breaks reference cycles (interpreted structs are class-backed, so a
    /// value graph CAN alias where a compiled struct never could).
    struct InstanceEqualityPair: Hashable {
        let lhs: ObjectIdentifier
        let rhs: ObjectIdentifier
    }
    var activeEqualityPairs: Set<InstanceEqualityPair> {
        get { evaluationTaskContext.activeEqualityPairs }
        set { evaluationTaskContext.activeEqualityPairs = newValue }
    }
    /// GLOBAL function overload sets (`func L10n(_:)` beside
    /// `func L10n(_:_ arguments: CVarArg...)`): globals hold one closure
    /// per name, so calls consult this table for shape choice.
    var globalFunctionOverloads: [String: [FunctionDeclSyntax]] = [:]

    /// Call-shape and closure metadata are properties of syntax declarations,
    /// not of individual invocations. Cache them by SwiftSyntax identity so
    /// overload dispatch never rebuilds syntax collections or descriptions.
    struct CallableShape {
        let parameterCount: Int
        let labels: Set<String>
        let wildcardCount: Int
        let requiredLabels: [String]

        func matches(_ arguments: ArgumentShape) -> Bool {
            guard arguments.count <= parameterCount,
                  arguments.labels.isSubset(of: labels),
                  arguments.unlabeledCount <= wildcardCount else { return false }
            var missingRequired = 0
            for label in requiredLabels where !arguments.labels.contains(label) {
                missingRequired += 1
                if missingRequired > arguments.unlabeledTrailingCount { return false }
            }
            return true
        }
    }

    struct ArgumentShape {
        let count: Int
        let labels: Set<String>
        let unlabeledCount: Int
        let unlabeledTrailingCount: Int

        init(_ arguments: CallArguments) {
            count = arguments.arguments.count
            var labels: Set<String> = []
            var unlabeledCount = 0
            var unlabeledTrailingCount = 0
            for argument in arguments.arguments {
                if let label = argument.label {
                    labels.insert(label)
                } else if argument.isTrailing {
                    unlabeledTrailingCount += 1
                } else {
                    unlabeledCount += 1
                }
            }
            self.labels = labels
            self.unlabeledCount = unlabeledCount
            self.unlabeledTrailingCount = unlabeledTrailingCount
        }
    }

    struct FunctionMetadata {
        let parameters: [ClosureValue.Parameter]
        let shape: CallableShape
        let returnType: TypeSyntax?
        let returnTypeName: String?
        let isBuilder: Bool
        let genericParameters: [String]
    }

    struct InitializerMetadata {
        let parameters: [ClosureValue.Parameter]
        let shape: CallableShape
    }

    var functionMetadataCache: [SyntaxIdentifier: FunctionMetadata] = [:]
    var initializerMetadataCache: [SyntaxIdentifier: InitializerMetadata] = [:]

    /// Per-view-IDENTITY state cells: compiled SwiftUI keeps @State/
    /// @StateObject storage alive across re-renders of the same position;
    /// re-evaluating a view tree must not reset interpreted state, or
    /// probe passes never see each other's writes (a TimelineViewModel's
    /// client assigned in .onAppear was invisible to the fetch pass).
    /// Identity = instantiation SITE + type + property. The initializer
    /// still evaluates each time and is DISCARDED on a known identity —
    /// exactly the @State autoclosure contract. ForEach rows share a
    /// site (documented divergence until element-id salting).
    struct ViewStateKey: Hashable {
        let site: SyntaxIdentifier
        let type: String
        let property: String
        /// ForEach element identity — sibling rows constructed at the SAME
        /// call site get distinct state (compiled SwiftUI's per-ID storage).
        let salt: String
    }
    var viewStateCells: [ViewStateKey: Box] = [:]
    var viewIdentitySalts: [String] {
        get { evaluationTaskContext.viewIdentitySalts }
        set { evaluationTaskContext.viewIdentitySalts = newValue }
    }

    /// Bracket a builder-row evaluation with the element's identity, so
    /// per-view state cells key by (site, element) instead of site alone.
    public func withViewIdentitySalt<T>(_ salt: String, _ body: () throws -> T) rethrows -> T {
        viewIdentitySalts.append(salt)
        defer { viewIdentitySalts.removeLast() }
        return try body()
    }
    static var traceStateCells = ProcessInfo.processInfo.environment["INTERP_TRACE_STATE"] != nil
    /// Process-level diagnostic selectors are immutable after launch. Reading
    /// `ProcessInfo.environment` inside identifier/initializer dispatch used
    /// to rebuild and bridge the complete environment on every hot-path call.
    static let tracedIdentifier = ProcessInfo.processInfo.environment["INTERP_TRACE_IDENT"]
    static let tracedInitializer = ProcessInfo.processInfo.environment["INTERP_TRACE_INIT"]
    /// Gated call-stack names for cycle diagnosis (nesting-guard dumps).
    var callStackNames: [String] {
        get { evaluationTaskContext.callStackNames }
        set { evaluationTaskContext.callStackNames = newValue }
    }
    /// Declaration → the symbol whose body/extension lexically holds it
    /// (StructSymbol or EnumSymbol), stamped at collection.
    var declLexicalOwners: [SyntaxIdentifier: AnyObject] = [:]
    /// The RUNNING function's declaring scopes, innermost last. Plain
    /// closures push nothing — they inherit their enclosing frame.
    var lexicalOwnerFrames: [AnyObject] {
        get { evaluationTaskContext.lexicalOwnerFrames }
        set { evaluationTaskContext.lexicalOwnerFrames = newValue }
    }
    /// The statically proven actor context for a closure expression. Source
    /// top-level execution is MainActor-owned; an explicit `nil` frame means
    /// the active declaration has no actor isolation even if it was invoked
    /// dynamically by a MainActor caller.
    var lexicalExecutorFrames: [RuntimeExecutorKind?] {
        get { evaluationTaskContext.lexicalExecutorFrames }
        set { evaluationTaskContext.lexicalExecutorFrames = newValue }
    }
    var currentLexicalExecutor: RuntimeExecutorKind? {
        guard !lexicalExecutorFrames.isEmpty else { return .mainActor }
        return lexicalExecutorFrames[lexicalExecutorFrames.count - 1]
    }

    /// Bare nested-type lookup with LEXICAL scoping: the running method's
    /// declaring type wins over the runtime self's (a protocol-extension
    /// body resolves names at its own scope — clean-architecture's
    /// `throw APIError.unexpectedResponse` inside `extension WebRepository`
    /// must not see the conforming test double's nested APIError).
    func lexicalNestedType(_ name: String, runtime: StructSymbol) -> RuntimeValue? {
        guard !lexicalOwnerFrames.isEmpty else {
            return runtime.nestedTypes[name]
        }
        // Deferred builder closures can nest several declaration scopes
        // (GeneralView → Container → Row). Search from the innermost scope
        // outward; an inner type that has no such declaration must not erase
        // the enclosing closure's nested type and fall through to globals.
        for owner in lexicalOwnerFrames.reversed() {
            if let symbol = owner as? StructSymbol,
               let nested = symbol.nestedTypes[name] {
                return nested
            }
            if let symbol = owner as? EnumSymbol,
               let nested = symbol.nestedTypes[name] {
                return nested
            }
        }
        return nil
    }

    /// Persistence is the LIVE-probe contract (LiveCheck's multi-pass render
    /// needs .onAppear writes visible to the fetch pass) — opt-in. M0 render
    /// probes keep fresh-per-instantiation state: their click-through replays
    /// collected actions against re-renders in an order no native run
    /// sequences, and persistent boxes turned that into stale index bindings
    /// (ImageDrawing) and shared-row projections (SwiftUIRealm).
    public var persistentViewState = false

    /// (instance, property) pairs whose observer is RUNNING — assignment
    /// inside one's own didSet must not re-trigger (compiled semantics).
    var activePropertyObservers: Set<ObserverKey> {
        get { evaluationTaskContext.activePropertyObservers }
        set { evaluationTaskContext.activePropertyObservers = newValue }
    }
    struct ObserverKey: Hashable {
        let instance: ObjectIdentifier
        let property: String
    }

    /// Call-site type annotations currently in scope (`let x: [Status] = …`
    /// pushes "[Status]" around its initializer): return-position generic
    /// parameters bind to the top, so `Entity.self` reaches decode with a
    /// REAL type value. Textual, innermost last.
    var expectedAnnotationStack: [String] {
        get { evaluationTaskContext.expectedAnnotationStack }
        set { evaluationTaskContext.expectedAnnotationStack = newValue }
    }
    var pendingDottedExtensions: [ExtensionDeclSyntax] = []
    /// Top-level typealias heads (`LoadableSubject` → `Binding`), for
    /// canonicalizing extension targets before resolution.
    var aliasHeads: [String: String] = [:]
    /// Member typealiases whose targets resolve only after the extension
    /// pass (typealias API = TestWebRepository.API).
    var pendingMemberAliases: [(StructSymbol, String, String)] = []
    /// Executor-owned deinitializers are classified only after every nominal
    /// declaration and typealias has been collected. The owning symbol keeps
    /// either a supported MainActor capability or a located unsupported
    /// requirement, so collection stays legal and construction fails closed
    /// only when no teardown capability exists.
    var pendingDeinitializerIsolationChecks: [
        (symbol: StructSymbol, declaration: DeinitializerDeclSyntax)
    ] = []
    /// Property/method collision preferences currently evaluating — the
    /// property's own body reaching the same name falls to the METHOD.
    var activeCollisionProperties: Set<String> {
        get { evaluationTaskContext.activeCollisionProperties }
        set { evaluationTaskContext.activeCollisionProperties = newValue }
    }
    var deferredExtensionRetry: Bool {
        get { evaluationTaskContext.deferredExtensionRetry }
        set { evaluationTaskContext.deferredExtensionRetry = newValue }
    }

    /// The DECLARED return type of each function on the call stack (nil for
    /// annotation-less closures, which mask the enclosing hint). An explicit
    /// `return expr` evaluates under the top entry, so `return try await
    /// client.get(…)` inside `-> [Status]` binds the callee's generic.
    var enclosingReturnAnnotations: [String?] {
        get { evaluationTaskContext.enclosingReturnAnnotations }
        set { evaluationTaskContext.enclosingReturnAnnotations = newValue }
    }

    func withExpectedAnnotation<T>(_ annotation: String?, _ body: () throws -> T) rethrows -> T {
        guard let annotation, !annotation.isEmpty else { return try body() }
        expectedAnnotationStack.append(annotation)
        defer { expectedAnnotationStack.removeLast() }
        return try body()
    }

    public init(
        registry: HostRegistry? = nil,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.registry = registry
        compilerPreflight = nil
        compilerPreflightMode = .disabled
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform)
        runtimeClock = ContinuousRuntimeClock()
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        defineGlobalBuiltins()
    }

    public init(
        registry: HostRegistry? = nil,
        compilerPreflight: SwiftCompilerPreflight,
        compilerPreflightMode: CompilerPreflightMode = .required,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.registry = registry
        self.compilerPreflight = compilerPreflight
        self.compilerPreflightMode = compilerPreflightMode
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform)
        runtimeClock = ContinuousRuntimeClock()
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        defineGlobalBuiltins()
    }

    public init(
        registry: HostRegistry? = nil,
        runtimeClock: any RuntimeClock,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.registry = registry
        compilerPreflight = nil
        compilerPreflightMode = .disabled
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform)
        self.runtimeClock = runtimeClock
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        defineGlobalBuiltins()
    }

    public init(
        registry: HostRegistry? = nil,
        runtimeClock: any RuntimeClock,
        compilerPreflight: SwiftCompilerPreflight,
        compilerPreflightMode: CompilerPreflightMode = .required,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.registry = registry
        self.compilerPreflight = compilerPreflight
        self.compilerPreflightMode = compilerPreflightMode
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform)
        self.runtimeClock = runtimeClock
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        defineGlobalBuiltins()
    }

    func functionMetadata(for node: FunctionDeclSyntax) -> FunctionMetadata {
        let identifier = Syntax(node).id
        if let cached = functionMetadataCache[identifier] { return cached }
        let parameters = node.signature.parameterClause.parameters
        let returnType = node.signature.returnClause?.type
        let returnTypeName = returnType?.trimmedDescription
        let returnsView = returnTypeName?.contains("some View") ?? false
        let isBuilder = returnsView || node.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
        let metadata = FunctionMetadata(
            parameters: closureParameters(from: parameters),
            shape: callableShape(from: parameters),
            returnType: returnType,
            returnTypeName: returnTypeName,
            isBuilder: isBuilder,
            genericParameters: node.genericParameterClause?.parameters.map(\.name.text) ?? [])
        functionMetadataCache[identifier] = metadata
        return metadata
    }

    func initializerMetadata(for node: InitializerDeclSyntax) -> InitializerMetadata {
        let identifier = Syntax(node).id
        if let cached = initializerMetadataCache[identifier] { return cached }
        let parameters = node.signature.parameterClause.parameters
        let metadata = InitializerMetadata(
            parameters: closureParameters(from: parameters),
            shape: callableShape(from: parameters))
        initializerMetadataCache[identifier] = metadata
        return metadata
    }

    private func closureParameters(
        from parameters: FunctionParameterListSyntax
    ) -> [ClosureValue.Parameter] {
        var result: [ClosureValue.Parameter] = []
        result.reserveCapacity(parameters.count)
        let backticks = CharacterSet(charactersIn: "`")
        for parameter in parameters {
            let firstName = parameter.firstName.text.trimmingCharacters(in: backticks)
            result.append(ClosureValue.Parameter(
                name: (parameter.secondName ?? parameter.firstName).text
                    .trimmingCharacters(in: backticks),
                label: firstName == "_" ? nil : firstName,
                defaultValue: parameter.defaultValue?.value,
                typeAnnotation: parameter.type,
                isBuilderAttributed: parameter.attributes.contains {
                    $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
                } || ClosureValue.Parameter.isBuilderAttributedType(parameter.type),
                isVariadic: parameter.ellipsis != nil,
                isIsolated: ClosureValue.Parameter.isIsolatedType(
                    parameter.type)))
        }
        return result
    }

    private func callableShape(from parameters: FunctionParameterListSyntax) -> CallableShape {
        var labels: Set<String> = []
        var wildcardCount = 0
        var requiredLabels: [String] = []
        requiredLabels.reserveCapacity(parameters.count)
        for parameter in parameters {
            let label = parameter.firstName.text
            labels.insert(label)
            if label == "_" {
                wildcardCount += 1
            } else if parameter.defaultValue == nil {
                requiredLabels.append(label)
            }
        }
        return CallableShape(
            parameterCount: parameters.count,
            labels: labels,
            wildcardCount: wildcardCount,
            requiredLabels: requiredLabels)
    }

}
