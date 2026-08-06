import Foundation
import SwiftSyntax

/// Per-interpreter conditional-compilation identity. Target-aware project
/// callers derive this from the same build target used by compiler preflight;
/// legacy callers retain the historical iOS + DEBUG canvas.
public nonisolated struct InterpreterBuildConfiguration: Sendable, Equatable {
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

    /// Whether source compiled for this interpreter target can import a
    /// module. Host bridges use this immutable target identity instead of
    /// inferring availability from the process platform.
    public func canImport(_ moduleName: String) -> Bool {
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

    /// Resolve one conditional-compilation expression from immutable target
    /// identity. Keeping this off the interpreter facade lets a parsed
    /// program build its complete target plan before mutable runtime state is
    /// materialized.
    func ifConfigConditionHolds(_ condition: ExprSyntax?) -> Bool {
        guard let condition else { return true } // #else
        if let paren = condition.as(TupleExprSyntax.self),
           paren.elements.count == 1,
           let only = paren.elements.first {
            return ifConfigConditionHolds(only.expression)
        }
        if let ref = condition.as(DeclReferenceExprSyntax.self) {
            return activeCompilationConditions.contains(ref.baseName.text)
        }
        if let call = condition.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let argument = call.arguments.first?.expression
                .trimmedDescription ?? ""
            switch callee.baseName.text {
            case "os":
                return argument == platformName
            case "arch":
                return argument == architecture
            case "canImport":
                if call.arguments.count == 2,
                   let versionArgument = call.arguments.last,
                   let versionKind = versionArgument.label?.text,
                   versionKind == "_version"
                        || versionKind == "_underlyingVersion" {
                    return canImport(
                        argument,
                        versionKind: versionKind,
                        version: versionArgument.expression
                            .trimmedDescription)
                }
                if call.arguments.count != 1,
                   authoritativeImportableModules != nil {
                    return false
                }
                return canImport(argument)
            case "swift":
                return swiftConditionalCompilationVersion?
                    .satisfies(argument) ?? true
            case "compiler":
                return compilerVersion?.satisfies(argument) ?? true
            case "targetEnvironment":
                return argument == targetEnvironment
            default:
                return conditionalCompilationQuery(
                    predicate: callee.baseName.text,
                    argument: argument) ?? false
            }
        }
        if let prefix = condition.as(PrefixOperatorExprSyntax.self),
           prefix.operator.text == "!" {
            return !ifConfigConditionHolds(prefix.expression)
        }
        if let infix = condition.as(InfixOperatorExprSyntax.self) {
            switch infix.operator.trimmedDescription {
            case "&&":
                return ifConfigConditionHolds(infix.leftOperand)
                    && ifConfigConditionHolds(infix.rightOperand)
            case "||":
                return ifConfigConditionHolds(infix.leftOperand)
                    || ifConfigConditionHolds(infix.rightOperand)
            default:
                break
            }
        }
        if let sequence = condition.as(SequenceExprSyntax.self) {
            // #if conditions are not operator-folded; handle && / || runs.
            let elements = Array(sequence.elements)
            let operators = stride(
                from: 1, to: elements.count, by: 2
            ).compactMap {
                elements[$0].as(BinaryOperatorExprSyntax.self)?.operator.text
            }
            let operands = stride(
                from: 0, to: elements.count, by: 2
            ).map { elements[$0] }
            if !operators.isEmpty,
               operators.allSatisfy({ $0 == "&&" }) {
                return operands.allSatisfy(ifConfigConditionHolds)
            }
            if !operators.isEmpty,
               operators.allSatisfy({ $0 == "||" }) {
                return operands.contains(where: ifConfigConditionHolds)
            }
        }
        return false
    }
}

/// The public facade: parse → fold operators → collect declarations → evaluate.
///
/// A tree-walking interpreter over SwiftSyntax ASTs. It implements no
/// framework functionality itself; anything beyond core language semantics is
/// delegated to a `HostRegistry` (the SwiftUI bridge, or a trace registry in
/// tests).
@MainActor
public final class Interpreter {
    /// Empty compatibility surface used only before the first program is
    /// prepared. Every executable program receives a distinct state object.
    private let bootstrapProgramState = RuntimeProgramState()
    public let runtimeHeap: RuntimeHeap
    public var globals: Environment { runtimeHeap.globals }
    let concurrencyRuntime: CooperativeConcurrencyRuntime
    public let runtimeClock: any RuntimeClock
    /// Compatibility/default bridge for future program preparation. Runtime
    /// entries resolve the exact registry captured by their program state.
    private var compatibilityRegistry: HostRegistry?
    public var registry: HostRegistry? {
        get {
            if let programState = evaluationTaskContext
                .programStateFrames.last
                ?? evaluationTaskContext.runtimeEntry?.programState {
                return programState.hostRegistry
            }
            return compatibilityRegistry
        }
        set { compatibilityRegistry = newValue }
    }
    public let compilerPreflight: SwiftCompilerPreflight?
    public let compilerPreflightMode: CompilerPreflightMode
    public let buildConfiguration: InterpreterBuildConfiguration
    public let executionMode: RuntimeExecutionMode
    let physicalWorkerDriver: RuntimePhysicalWorkerDriver?
    public internal(set) var lastCompilerPreflightResult:
        CompilerPreflightResult?
    /// Struct symbols in declaration order (used to pick the root View).
    public internal(set) var structSymbols: [StructSymbol] {
        _read { yield activeProgramState.structSymbols }
        _modify { yield &activeProgramState.structSymbols }
    }
    var enumSymbols: [String: EnumSymbol] {
        _read { yield activeProgramState.enumSymbols }
        _modify { yield &activeProgramState.enumSymbols }
    }
    var sourceModuleNamesByNominalIdentity:
        [ObjectIdentifier: Set<String>] {
        _read { yield activeProgramState.sourceModuleNamesByNominalIdentity }
        _modify { yield &activeProgramState.sourceModuleNamesByNominalIdentity }
    }
    /// Env-object models constructed as fresh-store stand-ins (one per type,
    /// so every view reading the type sees the same instance).
    var synthesizedEnvironmentModels: [String: Instance] {
        _read { yield runtimeHeap.synthesizedEnvironmentModels }
        _modify { yield &runtimeHeap.synthesizedEnvironmentModels }
    }
    /// Interpreted `extension View { … }` / `extension String { … }` members,
    /// keyed by the extended host type's name.
    var hostExtensionSymbols: [String: StructSymbol] {
        _read {
            let symbols = activeProgramState.visibleHostExtensionSymbols
            yield symbols
        }
        _modify { yield &activeProgramState.hostExtensionSymbols }
    }

    /// Names for which `hostExtensionSymbols[_]?.methods[name]` can be
    /// non-empty. Every other name is answerable without deriving the
    /// receiver's candidate type names.
    var hostExtensionMethodNames: Set<String> {
        activeProgramState.visibleHostExtensionMethodNames
    }

    /// Times the name guard above admitted a lookup to the candidate
    /// type-name walk. Observable so a regression pin can assert the walk
    /// stays off ordinary host member access rather than time it.
    var hostExtensionCandidateDerivationCount: Int {
        activeProgramState.hostExtensionCandidateDerivationCount
    }

    func noteHostExtensionCandidateDerivation() {
        activeProgramState.noteHostExtensionCandidateDerivation()
    }

    func mutableHostExtensionSymbol(named name: String) -> StructSymbol {
        if let symbol = activeProgramState.hostExtensionSymbols[name] {
            return symbol
        }
        let symbol = activeProgramState.visibleHostExtensionSymbols[name]?
            .copyForExtensionOverlay()
            ?? StructSymbol(name: name, conformsToView: false)
        activeProgramState.hostExtensionSymbols[name] = symbol
        return symbol
    }
    var assumesCompiledImports: Bool {
        activeProgramState.assumesCompiledImports
    }
    /// Legacy default captured by interpreters constructed without an
    /// explicit `InterpreterBuildConfiguration`. Target-manifest callers use
    /// immutable per-instance build identity instead.
    public static var interpretsAsPlatform = "iOS"
    /// Compilation conditions for default-configured interpreters — the
    /// `interpretsAsPlatform` idea for `#if DEBUG`-family gates. `swift
    /// build` (and the FoodTruck twin) are debug builds, so DEBUG is the
    /// default; the corpus driver flips to RELEASE semantics — what
    /// shipping users run (oss:Mythic's #if DEBUG back-step button traps
    /// by design when clicked at stage 0; release builds don't have it).
    public static var interpretsWithCompilationConditions: Set<String> = ["DEBUG"]
    /// RNG_TRACE diagnostics only.
    public static var rngDrawCount = 0
    /// Number of large finite loops prepared by this interpreter instance.
    /// Kept as a white-box metric so parity tests can prove that optimized
    /// semantics, rather than the tree-walking fallback, were exercised.
    private(set) var preparedFiniteLoopPlanCount = 0
    /// Nil collection elements whose structurally pure optional-chain
    /// transform returned none without allocating an invocation frame.
    private(set) var preparedOptionalChainNilSkipCount = 0
    var coreFunctionIntrinsics: [
        ObjectIdentifier: (function: HostFunction, intrinsic: CoreFunctionIntrinsic)
    ] = [:]

    func recordPreparedFiniteLoopPlan() {
        preparedFiniteLoopPlanCount += 1
    }

    func recordPreparedOptionalChainNilSkip() {
        preparedOptionalChainNilSkipCount += 1
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
    var protocolInheritance: [String: [String]] {
        _read { yield activeProgramState.protocolInheritance }
        _modify { yield &activeProgramState.protocolInheritance }
    }

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
        var queue: [String] = []
        var current: StructSymbol? = symbol
        var walked = Set<ObjectIdentifier>()
        while let candidate = current,
              walked.insert(ObjectIdentifier(candidate)).inserted {
            queue.append(contentsOf: candidate.conformances)
            current = interpretedSuperclass(of: candidate)
        }
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

    /// Source map used by compatibility-only synchronous parsing/evaluation.
    /// Canonical runtime work always reads the immutable converter retained
    /// by its exact RuntimeEntry plan, so a later facade run cannot relabel an
    /// escaped callback's diagnostics.
    var compatibilityLocationConverter: SourceLocationConverter?
    var locationConverter: SourceLocationConverter? {
        if let entry = evaluationTaskContext.runtimeEntry {
            return entry.programPlan?.locationConverter
                ?? entry.programState?.programPlan?.locationConverter
        }
        return compatibilityLocationConverter
    }
    /// Deliberately NOT `lazy`. Every synchronous evaluation falls back to
    /// this context, so a lazy binding puts an initialization check and its
    /// exclusivity enforcement on the interpreter's hottest read.
    private let synchronousEvaluationTaskContext: EvaluationTaskContext

    var evaluationTaskContext: EvaluationTaskContext {
        evaluationTaskContextResolutions &+= 1
        if let current = EvaluationTaskContext.current,
           current.concurrencyRuntime === concurrencyRuntime {
            return current
        }
        return synchronousEvaluationTaskContext
    }

    /// Times the owning task context was resolved — a task-local read plus a
    /// weak load. Observable so a regression pin can assert the per-node path
    /// resolves it ONCE per evaluated node rather than once per piece of
    /// bookkeeping, without timing anything.
    private(set) var evaluationTaskContextResolutions = 0

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
    var resolveAnnotatedDepth: Int {
        get { evaluationTaskContext.resolveAnnotatedDepth }
        set { evaluationTaskContext.resolveAnnotatedDepth = newValue }
    }
    var synchronousTaskDepth: Int {
        get { evaluationTaskContext.synchronousTaskDepth }
        set { evaluationTaskContext.synchronousTaskDepth = newValue }
    }
    /// Compatibility inspection view over the runtime-owned handle registry.
    var scheduledTasks: [RuntimeTaskHandle] {
        concurrencyRuntime.scheduledTaskHandles
    }
    /// Collision-free bindings used while lowering awaited subexpressions
    /// into the established synchronous expression machinery.
    var asyncTemporarySerial: Int {
        get { evaluationTaskContext.asyncTemporarySerial }
        set { evaluationTaskContext.asyncTemporarySerial = newValue }
    }
    /// Host-extension method frames currently executing (recursion guard:
    /// re-entrant same-name dispatch prefers the registry gateway).
    var activeExtensionFrames: Set<ExtensionFrame> {
        get { evaluationTaskContext.activeExtensionFrames }
        set { evaluationTaskContext.activeExtensionFrames = newValue }
    }
    /// DI-container resolution (`@Dependency(\.pool)`): instances are SHARED
    /// per type, and circular graphs break with an absorbing marker (real
    /// containers resolve cycles lazily).
    var dependencyCache: [String: RuntimeValue] {
        _read { yield activeProgramState.dependencyCache }
        _modify { yield &activeProgramState.dependencyCache }
    }
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
    var globalFunctionOverloads: [String: [FunctionDeclSyntax]] {
        _read { yield activeProgramState.globalFunctionOverloads }
        _modify { yield &activeProgramState.globalFunctionOverloads }
    }

    nonisolated struct ArgumentShape: Sendable {
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

        init(_ arguments: [ParsedCallArgumentMetadata]) {
            count = arguments.count
            var labels: Set<String> = []
            var unlabeledCount = 0
            var unlabeledTrailingCount = 0
            for argument in arguments {
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

    /// Last immutable program metadata used by the synchronous compatibility
    /// facade. Canonical async work resolves metadata from its RuntimeEntry;
    /// this fallback keeps post-run rendering/instantiation APIs source-
    /// compatible without rebuilding mutable syntax caches.
    var compatibilityProgramMetadata: ParsedProgramMetadata?
    /// Target-resolved counterpart of `compatibilityProgramMetadata`.
    /// Canonical async work reads its exact plan from RuntimeEntry; this
    /// fallback serves synchronous APIs and foreign syntax.
    var compatibilityProgramPlan: ResolvedProgramPlan?
    /// Mutable declaration registries for the last compatibility program.
    /// Canonical runtime work selects its exact state from RuntimeEntry.
    var compatibilityProgramState: RuntimeProgramState?

    private var lexicalProgramState: RuntimeProgramState? {
        evaluationTaskContext.programStateFrames.last
    }

    var currentProgramState: RuntimeProgramState? {
        lexicalProgramState
            ?? evaluationTaskContext.runtimeEntry?.programState
            ?? compatibilityProgramState
    }

    private var activeProgramState: RuntimeProgramState {
        currentProgramState ?? bootstrapProgramState
    }

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
    var viewStateCells: [ViewStateKey: Box] {
        _read { yield runtimeHeap.viewStateCells }
        _modify { yield &runtimeHeap.viewStateCells }
    }
    var viewIdentitySalts: [String] {
        get { evaluationTaskContext.viewIdentitySalts }
        set { evaluationTaskContext.viewIdentitySalts = newValue }
    }
    public var currentViewIdentityPath: String {
        viewIdentitySalts.joined(separator: "/")
    }

    /// Bracket a builder-row evaluation with the element's identity, so
    /// per-view state cells key by (site, element) instead of site alone.
    public func withViewIdentitySalt<T>(_ salt: String, _ body: () throws -> T) rethrows -> T {
        viewIdentitySalts.append("id:\(salt)")
        defer { viewIdentitySalts.removeLast() }
        return try body()
    }

    /// Re-enter the structural path captured when an interpreted view value
    /// was constructed. Body evaluation is deferred by host registries, so
    /// the ambient builder/parent path is otherwise gone by the time nested
    /// views and lifecycle modifiers are created.
    func withViewIdentityPath<T>(_ path: [String], _ body: () throws -> T) rethrows -> T {
        let previous = viewIdentitySalts
        viewIdentitySalts = path
        defer { viewIdentitySalts = previous }
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
    var declLexicalOwners: [SyntaxIdentifier: AnyObject] {
        _read {
            let owners = activeProgramState.visibleDeclarationLexicalOwners
            yield owners
        }
        _modify { yield &activeProgramState.declarationLexicalOwners }
    }

    func lexicalOwner(of declarationID: SyntaxIdentifier) -> AnyObject? {
        activeProgramState.lexicalOwner(of: declarationID)
    }

    func programStateOwningDeclaration(
        _ declarationID: SyntaxIdentifier?
    ) -> RuntimeProgramState? {
        guard let declarationID else { return currentProgramState }
        return currentProgramState?.stateOwningDeclaration(declarationID)
            ?? currentProgramState
    }
    /// The RUNNING function's declaring scopes, innermost last. Plain
    /// closures push nothing — they inherit their enclosing frame.
    var lexicalOwnerFrames: [AnyObject] {
        get { evaluationTaskContext.lexicalOwnerFrames }
        set { evaluationTaskContext.lexicalOwnerFrames = newValue }
    }
    var lexicalSourceModuleFrames: [String?] {
        get { evaluationTaskContext.lexicalSourceModuleFrames }
        set { evaluationTaskContext.lexicalSourceModuleFrames = newValue }
    }
    var currentLexicalSourceModuleName: String? {
        lexicalSourceModuleFrames.last ?? nil
    }
    var lexicalSourceImportFrames: [Set<String>?] {
        get { evaluationTaskContext.lexicalSourceImportFrames }
        set { evaluationTaskContext.lexicalSourceImportFrames = newValue }
    }
    var currentLexicalSourceImportedModuleNames: Set<String>? {
        lexicalSourceImportFrames.last ?? nil
    }
    var lexicalSourceFileFrames: [RuntimeSourceFileIdentity?] {
        get { evaluationTaskContext.lexicalSourceFileFrames }
        set { evaluationTaskContext.lexicalSourceFileFrames = newValue }
    }
    var currentLexicalSourceFileIdentity: RuntimeSourceFileIdentity? {
        lexicalSourceFileFrames.last ?? nil
    }

    /// Evaluate detached declaration syntax with the compiler-input module
    /// and imports selected by its immutable byte position. Stored-property
    /// defaults and lazy seeds do not enter through a source closure, so they
    /// otherwise lose the lexical visibility that ordinary accessors carry.
    func withLexicalSourceContext<T>(
        at sourcePosition: AbsolutePosition,
        programState: RuntimeProgramState? = nil,
        _ operation: () throws -> T
    ) rethrows -> T {
        let state = programState ?? currentProgramState
        evaluationTaskContext.enterProgramState(state)
        defer { evaluationTaskContext.leaveProgramState(state) }
        let metadata = state?.programPlan?.metadata ?? currentProgramMetadata
        lexicalSourceModuleFrames.append(
            metadata?.sourceModuleName(at: sourcePosition))
        lexicalSourceImportFrames.append(
            metadata?.sourceImportedModuleNames(at: sourcePosition))
        lexicalSourceFileFrames.append(
            metadata?.sourceFileIdentity(at: sourcePosition))
        defer {
            lexicalSourceFileFrames.removeLast()
            lexicalSourceImportFrames.removeLast()
            lexicalSourceModuleFrames.removeLast()
        }
        return try operation()
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

    func sourceModuleNames(owning value: RuntimeValue) -> Set<String> {
        let identity: ObjectIdentifier
        switch value {
        case .type(let symbol):
            identity = ObjectIdentifier(symbol)
        case .enumType(let symbol):
            identity = ObjectIdentifier(symbol)
        default:
            return []
        }
        return sourceModuleNamesByNominalIdentity[identity] ?? []
    }

    /// Resolve a nominal name from a declaration's lexical type scopes before
    /// consulting the merged global environment. Swift binds `EndTag: Tag`
    /// inside `Token` to `Token.Tag`, even when another source file declares
    /// an unrelated top-level `Tag`.
    func lexicallyVisibleType(
        named name: String, from owner: AnyObject?,
        sourceModuleName: String? = nil,
        sourceImportedModuleNames: Set<String>? = nil
    ) -> RuntimeValue? {
        let components = name.split(separator: ".").map(String.init)
        guard let first = components.first else { return nil }

        func nestedType(
            named component: String, in value: RuntimeValue
        ) -> RuntimeValue? {
            switch value {
            case .type(let symbol):
                return symbol.nestedTypes[component]
            case .enumType(let symbol):
                return symbol.nestedTypes[component]
            default:
                return nil
            }
        }

        func globallyVisibleType(
            named components: ArraySlice<String>
        ) -> RuntimeValue? {
            guard !components.isEmpty else { return nil }
            for prefixCount in stride(
                from: components.count, through: 1, by: -1
            ) {
                let prefix = components.prefix(prefixCount).joined(separator: ".")
                guard var resolved = typeValue(named: prefix) else { continue }
                var matched = true
                for component in components.dropFirst(prefixCount) {
                    guard let nested = nestedType(
                        named: component, in: resolved
                    ) else {
                        matched = false
                        break
                    }
                    resolved = nested
                }
                if matched { return resolved }
            }
            return nil
        }

        var current = owner
        var seen: Set<ObjectIdentifier> = []
        var root: RuntimeValue?
        while let scope = current,
              seen.insert(ObjectIdentifier(scope)).inserted {
            if let symbol = scope as? StructSymbol {
                if let nested = symbol.nestedTypes[first] {
                    root = nested
                    break
                }
                current = symbol.lexicalTypeOwner
            } else if let symbol = scope as? EnumSymbol {
                if let nested = symbol.nestedTypes[first] {
                    root = nested
                    break
                }
                current = symbol.lexicalTypeOwner
            } else {
                current = nil
            }
        }
        if let root {
            var resolved = root
            for component in components.dropFirst() {
                guard let nested = nestedType(named: component, in: resolved)
                else { return nil }
                resolved = nested
            }
            return resolved
        }

        let lexicalModule = sourceModuleName ?? currentLexicalSourceModuleName
        let hasFileScopedImports = sourceImportedModuleNames != nil
            || currentLexicalSourceImportedModuleNames != nil
        let lexicalImports = sourceImportedModuleNames
            ?? currentLexicalSourceImportedModuleNames
            ?? currentProgramMetadata?.importedModuleNames
            ?? ["Swift"]
        if let module = lexicalModule,
           let resolved = globallyVisibleType(
               named: ArraySlice([module] + components)) {
            return resolved
        }

        var importedNominalIsAmbiguous = false
        if lexicalModule != nil || hasFileScopedImports {
            var identities: Set<ObjectIdentifier> = []
            var candidates: [RuntimeValue] = []
            for importedModule in lexicalImports.sorted()
            where importedModule != lexicalModule {
                guard let candidate = globallyVisibleType(
                    named: ArraySlice([importedModule] + components))
                else { continue }
                let identity: ObjectIdentifier
                switch candidate {
                case .type(let symbol): identity = ObjectIdentifier(symbol)
                case .enumType(let symbol): identity = ObjectIdentifier(symbol)
                default: continue
                }
                if identities.insert(identity).inserted {
                    candidates.append(candidate)
                }
            }
            if candidates.count == 1 { return candidates[0] }
            importedNominalIsAmbiguous = candidates.count > 1
        }

        if components.count > 1,
           first == lexicalModule || lexicalImports.contains(first) {
            if let resolved = globallyVisibleType(named: components[...]) {
                return resolved
            }
            return globallyVisibleType(named: components.dropFirst())
        }

        if importedNominalIsAmbiguous { return nil }
        if let resolved = globallyVisibleType(named: components[...]) {
            // A bare nominal owned by some other flattened compiler module is
            // not visible merely because all modules share one Environment.
            // Same-module and explicitly imported candidates were exhausted
            // above; unowned snippet/shim declarations keep legacy lookup.
            if lexicalModule != nil || hasFileScopedImports,
               !sourceModuleNames(owning: resolved).isEmpty {
                return nil
            }
            return resolved
        }
        return nil
    }

    /// The identity-bound interpreted superclass, if one exists. Host
    /// superclass names deliberately return nil and retain their inert host
    /// behavior. The weak cache avoids repeating lexical lookup throughout
    /// initialization, dispatch, casting, and teardown.
    func interpretedSuperclass(of symbol: StructSymbol) -> StructSymbol? {
        if let parent = symbol.superclassSymbol {
            guard parent !== symbol else {
                symbol.superclassSymbol = nil
                return nil
            }
            return parent
        }
        guard let name = symbol.superclassName,
              let lookupName = Self.unspecializedNominalPath(name),
              case .type(let parent)? = lexicallyVisibleType(
                named: lookupName, from: symbol.lexicalTypeOwner),
              parent !== symbol else {
            return nil
        }
        symbol.superclassSymbol = parent
        return parent
    }

    /// A superclass specialization shares the declaration identity of its
    /// unspecialized nominal. Strip balanced generic argument clauses while
    /// preserving module and nested-type qualification:
    /// `Module.Base<Module.Value>.Child<Int>` → `Module.Base.Child`.
    private static func unspecializedNominalPath(_ rawName: String) -> String? {
        var result = ""
        var genericDepth = 0
        for character in rawName {
            switch character {
            case "<":
                genericDepth += 1
            case ">" where genericDepth > 0:
                genericDepth -= 1
            default:
                if genericDepth == 0 { result.append(character) }
            }
        }
        guard genericDepth == 0 else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Bind superclass identities after all declarations and deferred
    /// extensions are materialized, making forward sibling declarations
    /// independent of source-file order.
    func resolveInterpretedSuperclassSymbols() {
        for symbol in structSymbols where symbol.superclassName != nil {
            symbol.superclassSymbol = nil
            _ = interpretedSuperclass(of: symbol)
        }
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
    var pendingDottedExtensions: [ExtensionDeclSyntax] {
        _read { yield activeProgramState.pendingDottedExtensions }
        _modify { yield &activeProgramState.pendingDottedExtensions }
    }
    var nonNominalExtensionTypeNames: Set<String> {
        _read { yield activeProgramState.nonNominalExtensionTypeNames }
        _modify { yield &activeProgramState.nonNominalExtensionTypeNames }
    }
    /// Top-level typealias heads (`LoadableSubject` → `Binding`), for
    /// canonicalizing extension targets before resolution.
    var aliasHeads: [String: String] {
        _read { yield activeProgramState.aliasHeads }
        _modify { yield &activeProgramState.aliasHeads }
    }
    var topLevelTypeAliasBindings: [
        String: [RuntimeProgramState.TopLevelTypeAliasBinding]
    ] {
        _read { yield activeProgramState.topLevelTypeAliasBindings }
        _modify { yield &activeProgramState.topLevelTypeAliasBindings }
    }

    /// Follow a free top-level alias only when its declaring compiler module
    /// is visible at the active source file. Flattening several SwiftPM
    /// targets must not let one target's private `typealias Color = UIColor`
    /// redirect an unrelated target's imported SwiftUI `Color` constructor.
    /// Sources without file/module provenance retain the legacy single-file
    /// behavior, while exported aliases from explicit imports remain visible.
    func lexicallyVisibleTypeAliasHead(
        named name: String,
        sourceModuleName: String? = nil,
        sourceImportedModuleNames: Set<String>? = nil
    ) -> String? {
        let lexicalModule = sourceModuleName ?? currentLexicalSourceModuleName
        let hasFileScopedImports = sourceImportedModuleNames != nil
            || currentLexicalSourceImportedModuleNames != nil
        guard lexicalModule != nil || hasFileScopedImports else {
            return aliasHeads[name]
        }
        guard let bindings = topLevelTypeAliasBindings[name] else {
            return nil
        }

        if let lexicalModule,
           let local = bindings.last(where: {
               $0.sourceModuleName == lexicalModule
           }) {
            return local.targetName
        }

        let lexicalImports = sourceImportedModuleNames
            ?? currentLexicalSourceImportedModuleNames
            ?? currentProgramMetadata?.importedModuleNames
            ?? ["Swift"]
        let importedTargets = Set(bindings.compactMap { binding -> String? in
            guard binding.isExported,
                  let module = binding.sourceModuleName,
                  lexicalImports.contains(module) else { return nil }
            return binding.targetName
        })
        if importedTargets.count == 1 { return importedTargets.first }
        if importedTargets.count > 1 { return nil }

        let unownedTargets = Set(bindings.compactMap {
            $0.sourceModuleName == nil ? $0.targetName : nil
        })
        return unownedTargets.count == 1 ? unownedTargets.first : nil
    }
    var typeAliasTargets: [String: String] {
        _read { yield activeProgramState.typeAliasTargets }
        _modify { yield &activeProgramState.typeAliasTargets }
    }
    func typeAliasTarget(named name: String) -> String? {
        activeProgramState.typeAliasTarget(named: name)
    }
    /// Member typealiases whose targets resolve only after the extension
    /// pass (typealias API = TestWebRepository.API).
    var pendingMemberAliases: [
        RuntimeProgramState.PendingMemberAlias
    ] {
        _read { yield activeProgramState.pendingMemberAliases }
        _modify { yield &activeProgramState.pendingMemberAliases }
    }
    /// Executor-owned deinitializers are classified only after every nominal
    /// declaration and typealias has been collected. The owning symbol keeps
    /// either a supported MainActor capability or a located unsupported
    /// requirement, so collection stays legal and construction fails closed
    /// only when no teardown capability exists.
    var pendingDeinitializerIsolationChecks: [
        RuntimeProgramState.PendingDeinitializerIsolationCheck
    ] {
        _read { yield activeProgramState.pendingDeinitializerIsolationChecks }
        _modify {
            yield &activeProgramState.pendingDeinitializerIsolationChecks
        }
    }
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

    public convenience init(
        registry: HostRegistry? = nil,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.init(
            registry: registry,
            buildConfiguration: buildConfiguration,
            executionMode: .cooperative)
    }

    public init(
        registry: HostRegistry? = nil,
        buildConfiguration: InterpreterBuildConfiguration? = nil,
        executionMode: RuntimeExecutionMode
    ) {
        runtimeHeap = RuntimeHeap()
        compatibilityRegistry = registry
        compilerPreflight = nil
        compilerPreflightMode = .disabled
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform,
                activeCompilationConditions: Self.interpretsWithCompilationConditions)
        self.executionMode = executionMode
        physicalWorkerDriver = Self.makePhysicalWorkerDriver(
            for: executionMode)
        runtimeClock = ContinuousRuntimeClock()
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        synchronousEvaluationTaskContext = EvaluationTaskContext(
            id: 0, concurrencyRuntime: concurrencyRuntime)
        defineGlobalBuiltins()
    }

    public convenience init(
        registry: HostRegistry? = nil,
        compilerPreflight: SwiftCompilerPreflight,
        compilerPreflightMode: CompilerPreflightMode = .required,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.init(
            registry: registry,
            compilerPreflight: compilerPreflight,
            compilerPreflightMode: compilerPreflightMode,
            buildConfiguration: buildConfiguration,
            executionMode: .cooperative)
    }

    public init(
        registry: HostRegistry? = nil,
        compilerPreflight: SwiftCompilerPreflight,
        compilerPreflightMode: CompilerPreflightMode = .required,
        buildConfiguration: InterpreterBuildConfiguration? = nil,
        executionMode: RuntimeExecutionMode
    ) {
        runtimeHeap = RuntimeHeap()
        compatibilityRegistry = registry
        self.compilerPreflight = compilerPreflight
        self.compilerPreflightMode = compilerPreflightMode
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform,
                activeCompilationConditions: Self.interpretsWithCompilationConditions)
        self.executionMode = executionMode
        physicalWorkerDriver = Self.makePhysicalWorkerDriver(
            for: executionMode)
        runtimeClock = ContinuousRuntimeClock()
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        synchronousEvaluationTaskContext = EvaluationTaskContext(
            id: 0, concurrencyRuntime: concurrencyRuntime)
        defineGlobalBuiltins()
    }

    public convenience init(
        registry: HostRegistry? = nil,
        runtimeClock: any RuntimeClock,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.init(
            registry: registry,
            runtimeClock: runtimeClock,
            buildConfiguration: buildConfiguration,
            executionMode: .cooperative)
    }

    public init(
        registry: HostRegistry? = nil,
        runtimeClock: any RuntimeClock,
        buildConfiguration: InterpreterBuildConfiguration? = nil,
        executionMode: RuntimeExecutionMode
    ) {
        runtimeHeap = RuntimeHeap()
        compatibilityRegistry = registry
        compilerPreflight = nil
        compilerPreflightMode = .disabled
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform,
                activeCompilationConditions: Self.interpretsWithCompilationConditions)
        self.executionMode = executionMode
        physicalWorkerDriver = Self.makePhysicalWorkerDriver(
            for: executionMode)
        self.runtimeClock = runtimeClock
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        synchronousEvaluationTaskContext = EvaluationTaskContext(
            id: 0, concurrencyRuntime: concurrencyRuntime)
        defineGlobalBuiltins()
    }

    public convenience init(
        registry: HostRegistry? = nil,
        runtimeClock: any RuntimeClock,
        compilerPreflight: SwiftCompilerPreflight,
        compilerPreflightMode: CompilerPreflightMode = .required,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) {
        self.init(
            registry: registry,
            runtimeClock: runtimeClock,
            compilerPreflight: compilerPreflight,
            compilerPreflightMode: compilerPreflightMode,
            buildConfiguration: buildConfiguration,
            executionMode: .cooperative)
    }

    public init(
        registry: HostRegistry? = nil,
        runtimeClock: any RuntimeClock,
        compilerPreflight: SwiftCompilerPreflight,
        compilerPreflightMode: CompilerPreflightMode = .required,
        buildConfiguration: InterpreterBuildConfiguration? = nil,
        executionMode: RuntimeExecutionMode
    ) {
        runtimeHeap = RuntimeHeap()
        compatibilityRegistry = registry
        self.compilerPreflight = compilerPreflight
        self.compilerPreflightMode = compilerPreflightMode
        self.buildConfiguration = buildConfiguration
            ?? InterpreterBuildConfiguration(
                platformName: Self.interpretsAsPlatform,
                activeCompilationConditions: Self.interpretsWithCompilationConditions)
        self.executionMode = executionMode
        physicalWorkerDriver = Self.makePhysicalWorkerDriver(
            for: executionMode)
        self.runtimeClock = runtimeClock
        concurrencyRuntime = CooperativeConcurrencyRuntime(clock: runtimeClock)
        synchronousEvaluationTaskContext = EvaluationTaskContext(
            id: 0, concurrencyRuntime: concurrencyRuntime)
        defineGlobalBuiltins()
    }

    private static func makePhysicalWorkerDriver(
        for mode: RuntimeExecutionMode
    ) -> RuntimePhysicalWorkerDriver? {
        guard case .parallel(let configuration) = mode else { return nil }
        return RuntimePhysicalWorkerDriver(configuration: configuration)
    }

    var currentProgramMetadata: ParsedProgramMetadata? {
        lexicalProgramState?.programPlan?.metadata
            ?? evaluationTaskContext.runtimeEntry?.programMetadata
            ?? currentProgramPlan?.metadata
            ?? compatibilityProgramMetadata
    }

    var currentProgramPlan: ResolvedProgramPlan? {
        lexicalProgramState?.programPlan
            ?? evaluationTaskContext.runtimeEntry?.programPlan
            ?? compatibilityProgramState?.programPlan
            ?? compatibilityProgramPlan
    }

    var currentCallableMetadataIndex: ParsedCallableMetadataIndex? {
        currentProgramMetadata?.callableMetadataIndex
    }

    var currentCallSiteMetadataIndex: ParsedCallSiteMetadataIndex? {
        currentProgramMetadata?.callSiteMetadataIndex
    }

    var currentMemberMetadataIndex: ParsedMemberMetadataIndex? {
        currentProgramMetadata?.memberMetadataIndex
    }

    func memberMetadata(
        for block: MemberBlockSyntax
    ) -> ParsedMemberBlockMetadata {
        currentMemberMetadataIndex?.metadata(for: block)
            ?? ParsedMemberBlockMetadata(block)
    }

    func memberDeclarations(
        in block: MemberBlockSyntax
    ) -> [ParsedMemberDeclaration] {
        if let declarations = currentProgramPlan?.memberDeclarations(in: block) {
            return declarations
        }
        return memberMetadata(for: block).resolve(conditionHolds: {
            ifConfigConditionHolds($0)
        })
    }

    var currentNominalMetadataIndex: ParsedNominalMetadataIndex? {
        currentProgramMetadata?.nominalMetadataIndex
    }

    var currentPropertyMetadataIndex: ParsedPropertyMetadataIndex? {
        currentProgramMetadata?.propertyMetadataIndex
    }

    var currentEnumCaseMetadataIndex: ParsedEnumCaseMetadataIndex? {
        currentProgramMetadata?.enumCaseMetadataIndex
    }

    var currentExtensionMetadataIndex: ParsedExtensionMetadataIndex? {
        currentProgramMetadata?.extensionMetadataIndex
    }

    func extensionMetadata(
        for node: ExtensionDeclSyntax
    ) -> ParsedExtensionMetadata {
        currentExtensionMetadataIndex?.metadata(for: node)
            ?? ParsedExtensionMetadata(node)
    }

    var currentTypeAliasMetadataIndex: ParsedTypeAliasMetadataIndex? {
        currentProgramMetadata?.typeAliasMetadataIndex
    }

    func typeAliasMetadata(
        for node: TypeAliasDeclSyntax
    ) -> ParsedTypeAliasMetadata {
        currentTypeAliasMetadataIndex?.metadata(for: node)
            ?? ParsedTypeAliasMetadata(node)
    }

    var currentDeinitializerMetadataIndex:
        ParsedDeinitializerMetadataIndex?
    {
        currentProgramMetadata?.deinitializerMetadataIndex
    }

    func deinitializerMetadata(
        for node: DeinitializerDeclSyntax
    ) -> ParsedDeinitializerMetadata {
        currentDeinitializerMetadataIndex?.metadata(for: node)
            ?? ParsedDeinitializerMetadata(node)
    }

    func enumCaseMetadata(
        for node: EnumCaseElementSyntax
    ) -> ParsedEnumCaseMetadata {
        currentEnumCaseMetadataIndex?.metadata(for: node)
            ?? ParsedEnumCaseMetadata(node)
    }

    func propertyMetadata(
        for node: VariableDeclSyntax
    ) -> ParsedVariablePropertyMetadata {
        currentPropertyMetadataIndex?.metadata(for: node)
            ?? ParsedVariablePropertyMetadata(node)
    }

    func propertyMetadata(
        for node: PatternBindingSyntax
    ) -> ParsedPropertyBindingMetadata {
        currentPropertyMetadataIndex?.metadata(for: node)
            ?? ParsedPropertyBindingMetadata(node)
    }

    func functionMetadata(
        for node: FunctionDeclSyntax
    ) -> ParsedFunctionMetadata {
        currentCallableMetadataIndex?.metadata(for: node)
            ?? ParsedFunctionMetadata(node)
    }

    func callSiteMetadata(
        for node: FunctionCallExprSyntax
    ) -> ParsedCallSiteMetadata {
        currentCallSiteMetadataIndex?.metadata(for: node)
            ?? ParsedCallSiteMetadata(node)
    }

    func initializerMetadata(
        for node: InitializerDeclSyntax
    ) -> ParsedInitializerMetadata {
        currentCallableMetadataIndex?.metadata(for: node)
            ?? ParsedInitializerMetadata(node)
    }

    func accessorMetadata(
        for node: AccessorBlockSyntax
    ) -> ParsedAccessorMetadata? {
        currentCallableMetadataIndex?.metadata(for: node)
            ?? ParsedAccessorMetadata(node)
    }

    func subscriptMetadata(
        for node: SubscriptDeclSyntax
    ) -> ParsedSubscriptMetadata {
        currentCallableMetadataIndex?.metadata(for: node)
            ?? ParsedSubscriptMetadata(node)
    }

    func nominalMetadata(
        for node: StructDeclSyntax
    ) -> ParsedNominalMetadata {
        currentNominalMetadataIndex?.metadata(for: node)
            ?? ParsedNominalMetadata(node)
    }

    func nominalMetadata(
        for node: ClassDeclSyntax
    ) -> ParsedNominalMetadata {
        currentNominalMetadataIndex?.metadata(for: node)
            ?? ParsedNominalMetadata(node)
    }

    func nominalMetadata(
        for node: ActorDeclSyntax
    ) -> ParsedNominalMetadata {
        currentNominalMetadataIndex?.metadata(for: node)
            ?? ParsedNominalMetadata(node)
    }

    func nominalMetadata(
        for node: EnumDeclSyntax
    ) -> ParsedNominalMetadata {
        currentNominalMetadataIndex?.metadata(for: node)
            ?? ParsedNominalMetadata(node)
    }

    func nominalMetadata(
        for node: ProtocolDeclSyntax
    ) -> ParsedNominalMetadata {
        currentNominalMetadataIndex?.metadata(for: node)
            ?? ParsedNominalMetadata(node)
    }

}
