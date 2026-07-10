import Foundation
import SwiftSyntax
import SwiftParser
import SwiftOperators
import SwiftParserDiagnostics

/// The public facade: parse → fold operators → collect declarations → evaluate.
///
/// A tree-walking interpreter over SwiftSyntax ASTs. It implements no
/// framework functionality itself; anything beyond core language semantics is
/// delegated to a `HostRegistry` (the SwiftUI bridge, or a trace registry in
/// tests).
public final class Interpreter {
    public let globals = Environment()
    public var registry: HostRegistry?
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

    func resolveTransitiveViewConformance() {
        guard !protocolInheritance.isEmpty else { return }
        for symbol in structSymbols where !symbol.conformsToView {
            var seen = Set<String>()
            if symbol.conformances.contains(where: { protocolReachesView($0, seen: &seen) }) {
                symbol.conformsToView = true
            }
        }
    }

    /// The symbol's body accessor: its OWN computed property, or a
    /// protocol-extension default (SwiftUIFlux's ConnectedView serves `body`
    /// from `extension ConnectedView`).
    func bodyProperty(of symbol: StructSymbol) -> ComputedProperty? {
        if let own = symbol.computedProperties["body"] { return own }
        for conformance in symbol.conformances {
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

    func recordAbsorbedHostMember(type typeName: String, member: String) {
        let key = "\(typeName).\(member)"
        if absorbedHostMembers[key] == nil, absorbedHostMembers.count >= 512 { return }
        absorbedHostMembers[key, default: 0] += 1
    }

    var locationConverter: SourceLocationConverter?
    var steps = 0
    /// Guards against `while true {}` freezing the UI: evaluation is main-actor.
    let stepBudget = 100_000
    /// Guards against runaway interpreted recursion overflowing the NATIVE
    /// stack (each interpreted call is ~10 Swift frames) before the step
    /// budget can trip. Fatal — never catchable by interpreted code.
    var callDepth = 0
    let callDepthLimit = 200
    var evaluationDepth = 0
    var resolveAnnotatedDepth = 0
    /// Host-extension method frames currently executing (recursion guard:
    /// re-entrant same-name dispatch prefers the registry gateway).
    var activeExtensionFrames: Set<ExtensionFrame> = []
    /// DI-container resolution (`@Dependency(\.pool)`): instances are SHARED
    /// per type, and circular graphs break with an absorbing marker (real
    /// containers resolve cycles lazily).
    var dependencyCache: [String: RuntimeValue] = [:]
    var dependencyInFlight: Set<String> = []
    /// Initializer bodies currently executing — self-delegation must not
    /// re-enter the same init (extension convenience → memberwise).
    var activeInitializers: Set<SyntaxIdentifier> = []
    /// Instances whose declared `init` body is currently executing: self-
    /// stores inside init are DIRECT (compiled semantics — willSet/didSet
    /// never fire during initialization).
    var initializingInstances: Set<ObjectIdentifier> = []
    /// Function bodies currently executing — overload dispatch excludes the
    /// running declaration (`send(_:) -> StoreTask` delegating to
    /// `send(_:) -> Task?`, identical shapes, return-type disambiguated).
    var activeFunctionBodies: Set<SyntaxIdentifier> = []
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
    var viewIdentitySalts: [String] = []

    /// Bracket a builder-row evaluation with the element's identity, so
    /// per-view state cells key by (site, element) instead of site alone.
    public func withViewIdentitySalt<T>(_ salt: String, _ body: () throws -> T) rethrows -> T {
        viewIdentitySalts.append(salt)
        defer { viewIdentitySalts.removeLast() }
        return try body()
    }
    static let traceStateCells = ProcessInfo.processInfo.environment["INTERP_TRACE_STATE"] != nil

    /// Persistence is the LIVE-probe contract (LiveCheck's multi-pass render
    /// needs .onAppear writes visible to the fetch pass) — opt-in. M0 render
    /// probes keep fresh-per-instantiation state: their click-through replays
    /// collected actions against re-renders in an order no native run
    /// sequences, and persistent boxes turned that into stale index bindings
    /// (ImageDrawing) and shared-row projections (SwiftUIRealm).
    public var persistentViewState = false

    /// (instance, property) pairs whose observer is RUNNING — assignment
    /// inside one's own didSet must not re-trigger (compiled semantics).
    var activePropertyObservers: Set<ObserverKey> = []
    struct ObserverKey: Hashable {
        let instance: ObjectIdentifier
        let property: String
    }

    /// Call-site type annotations currently in scope (`let x: [Status] = …`
    /// pushes "[Status]" around its initializer): return-position generic
    /// parameters bind to the top, so `Entity.self` reaches decode with a
    /// REAL type value. Textual, innermost last.
    var expectedAnnotationStack: [String] = []

    /// The DECLARED return type of each function on the call stack (nil for
    /// annotation-less closures, which mask the enclosing hint). An explicit
    /// `return expr` evaluates under the top entry, so `return try await
    /// client.get(…)` inside `-> [Status]` binds the callee's generic.
    var enclosingReturnAnnotations: [String?] = []

    func withExpectedAnnotation<T>(_ annotation: String?, _ body: () throws -> T) rethrows -> T {
        guard let annotation, !annotation.isEmpty else { return try body() }
        expectedAnnotationStack.append(annotation)
        defer { expectedAnnotationStack.removeLast() }
        return try body()
    }

    public init(registry: HostRegistry? = nil) {
        self.registry = registry
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
                isVariadic: parameter.ellipsis != nil))
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

    /// Formatting recoveries that parse to a CORRECT tree — the compiler
    /// accepts these spellings too.
    public static func isToleratedParseRecovery(_ message: String) -> Bool {
        message.contains("extraneous whitespace")
            // The `(@MainActor() -> Void)?` no-space family: the attribute
            // swallows the parens, SwiftParser recovers to a correct tree,
            // and Xcode accepts the spelling.
            || message.contains("expected '(' to start function type")
            || message.contains("expected ')' in function type")
            || message.contains("expected '(', type, and ')' in function type")
            // `throws async` — the parser recovers by normalizing effect
            // order; the tree carries both effects correctly.
            || message.contains("must precede 'throws'")
    }

    /// True when the source has HARD parse errors (recovered formatting
    /// diagnostics don't count) — such a file can't be a member of any
    /// compiling target (Sourcery scratch fragments, abandoned files with
    /// editor placeholders).
    public static func sourceHasHardErrors(_ source: String) -> Bool {
        let tree = Parser.parse(source: source)
        return ParseDiagnosticsGenerator.diagnostics(for: tree).contains {
            $0.diagMessage.severity == .error && !isToleratedParseRecovery($0.message)
        }
    }

    // MARK: - Parsing

    public func parse(source: String) throws -> SourceFileSyntax {
        // SwiftParser's default nesting ceiling (~256) trips on generated
        // preview fixtures (apple-browsers nests bookmark literals dozens
        // deep). Evaluation has its own stack probe; parsing gets headroom.
        var parser = Parser(source, maximumNestingLevel: 2_048)
        let tree = SourceFileSyntax.parse(from: &parser)
        let converter = SourceLocationConverter(fileName: "input.swift", tree: tree)
        locationConverter = converter

        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        if let firstError = diagnostics.first(where: {
            $0.diagMessage.severity == .error && !Self.isToleratedParseRecovery($0.message)
        }) {
            let location = converter.location(for: firstError.position)
            throw RuntimeError(message: firstError.message, line: location.line, column: location.column)
        }

        var operatorErrors: [OperatorError] = []
        // User-declared operators and precedence groups (Point-Free's
        // `|>` pipe) join the fold table; conflicts with the standard set
        // are tolerated (last declaration wins inside addSourceFile).
        var table = OperatorTable.standardOperators
        try? table.addSourceFile(tree) { _ in }
        let folded = table.foldAll(tree) { operatorErrors.append($0) }
        if let first = operatorErrors.first(where: {
            // Operators declared in EXTERNAL modules (Overture's `|>`)
            // recover with default precedence — the evaluator gives them
            // meaning (or absorbs). Other fold errors stay fatal.
            if case .missingOperator = $0 { return false }
            return true
        }) {
            throw RuntimeError(message: "operator error: \(first)", line: 1, column: 1)
        }
        guard let foldedFile = folded.as(SourceFileSyntax.self) else {
            throw RuntimeError(message: "internal error: operator folding failed", line: 1, column: 1)
        }
        return foldedFile
    }

    // MARK: - Running programs

    /// Parse and run a whole program: type/function declarations are hoisted,
    /// then top-level statements execute in order. Returns the value of the
    /// last top-level expression (handy for tests and for `ContentView()` as
    /// an explicit root).
    @discardableResult
    /// `lazyTopLevelGlobals`: multi-file merges (ProjectCheck units) have
    /// no main.swift — every top-level global is a LIBRARY global, which
    /// real Swift initializes lazily on first use. Single-source programs
    /// keep eager main.swift semantics (statement order matters in tests).
    public func run(source: String, lazyTopLevelGlobals: Bool = false) throws -> RuntimeValue {
        let file = try parse(source: source)
        steps = 0
        // Merged multi-file units COMPILE on device: an unresolved
        // identifier there is an unmerged import, never a typo.
        assumesCompiledImports = lazyTopLevelGlobals
        try collectDeclarations(from: file)
        resolveTransitiveViewConformance()

        var last: RuntimeValue = .void
        for item in expandedTopLevelItems(file.statements) {
            if case .stmt(let stmt) = item.item, stmt.is(DeferStmtSyntax.self) {
                // Top-level `defer` runs at PROCESS exit on device — the
                // harness has no such moment; cleanup-at-exit is invisible
                // to rendering, so the body is honestly skipped.
                continue
            }
            if case .decl(let decl) = item.item,
               decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self)
                || decl.is(ActorDeclSyntax.self) || decl.is(ImportDeclSyntax.self)
                || decl.is(FunctionDeclSyntax.self) || decl.is(ProtocolDeclSyntax.self)
                || decl.is(OperatorDeclSyntax.self) || decl.is(PrecedenceGroupDeclSyntax.self)
                || decl.is(TypeAliasDeclSyntax.self)
                || decl.is(EnumDeclSyntax.self) || decl.is(ExtensionDeclSyntax.self) {
                continue // already collected (protocols: requirements carry
                // no bodies; defaults live in their extensions)
            }
            if lazyTopLevelGlobals, case .decl(let decl) = item.item,
               let varDecl = decl.as(VariableDeclSyntax.self), isHoistableGlobal(varDecl) {
                continue // library globals: initialize on first reference
            }
            if case .decl(let decl) = item.item,
               let varDecl = decl.as(VariableDeclSyntax.self),
               varDecl.bindings.allSatisfy({ $0.accessorBlock != nil }) {
                continue // computed globals were collected; accessors run on read
            }
            if case .decl(let decl) = item.item,
               let varDecl = decl.as(VariableDeclSyntax.self), isHoistableGlobal(varDecl) {
                // Hoisted as lazy for FORWARD references; still executed
                // eagerly in statement order (main.swift semantics) unless a
                // forward reference already forced it — then re-running would
                // clobber mutations and repeat side effects.
                let alreadyForced = varDecl.bindings.contains { binding in
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                          let box = globals.box(for: ident.identifier.text) else { return false }
                    if case .host(let any) = box.value, any is LazyGlobal { return false }
                    return true
                }
                if alreadyForced { continue }
            }
            let result: StatementResult
            do {
                result = try execute(item, in: globals)
            } catch is InterpretedThrow where assumesCompiledImports {
                // A top-level statement's uncaught throw crashes only the
                // SCRIPT file that threw on device (session-ios ships repo
                // tooling whose file reads legitimately fail in the
                // sandbox); the merged unit's other files are independent.
                continue
            } catch let scriptError as RuntimeError
                where assumesCompiledImports && !scriptError.fatal {
                // Same doctrine for trap guards (`fatalError("Source file
                // had no content")` in tooling): the script's crash is its
                // own; budget/stack trips stay fatal.
                continue
            }
            switch result {
            case .normal(let value):
                last = value
            case .returnValue(let value):
                return value
            case .breakLoop, .continueLoop:
                throw RuntimeError(message: "break/continue outside a loop", line: 1, column: 1)
            }
        }
        return last
    }

    // MARK: - Instances

    /// A builder-attributed stored property builds from its trailing closure:
    /// `[X]`-annotated properties collect the block's items into an ARRAY
    /// (custom @resultBuilders' buildBlock), view-typed ones group as views.
    func builderValue(for property: StructSymbol.StoredProperty, closure: ClosureValue) throws -> RuntimeValue {
        let items = try callBuilderClosure(closure, arguments: [])
        let annotation = property.typeAnnotation?.trimmedDescription ?? ""
        if annotation.hasPrefix("[") {
            return .native(items)
        }
        return try groupViews(items)
    }


    /// Custom `init`s run with `self` bound to a defaults-initialized instance;
    /// otherwise default + memberwise initialization applies. `$binding`
    /// arguments for `@Binding` properties share the parent's Box.
    /// The symbol's stored properties plus its INTERPRETED superclass
    /// chain's (base-first, child names win) — inherited storage is real.
    func inheritedStoredProperties(of symbol: StructSymbol) -> [StructSymbol.StoredProperty] {
        var chain: [StructSymbol] = []
        var current: StructSymbol? = symbol
        var guardSet: Set<ObjectIdentifier> = []
        while let symbol = current, guardSet.insert(ObjectIdentifier(symbol)).inserted {
            chain.append(symbol)
            if let superName = symbol.superclassName,
               case .type(let parent)? = globals.lookup(superName) {
                current = parent
            } else {
                current = nil
            }
        }
        var seen: Set<String> = []
        var merged: [StructSymbol.StoredProperty] = []
        for symbol in chain { // child first: child declarations win
            for property in symbol.storedProperties where seen.insert(property.name).inserted {
                merged.append(property)
            }
        }
        return merged
    }

    public func instantiate(_ symbol: StructSymbol, with args: CallArguments, node: Syntax? = nil) throws -> RuntimeValue {
        let instance = Instance(symbol: symbol)
        let notifying = Set(symbol.notifyingPropertyNames)
        for property in inheritedStoredProperties(of: symbol) {
            // Optional-typed properties without initializers are nil in Swift.
            let annotationText = property.typeAnnotation?.trimmedDescription ?? ""
            var value: RuntimeValue = annotationText.hasSuffix("?") || annotationText.hasSuffix("!")
                ? .nilValue : .void
            if property.isLazy, let initializer = property.initializer {
                // `lazy var` defers to FIRST ACCESS with self bound —
                // sibling-property references are legal there.
                let box = Box(.native(LazyMemberSeed(
                    initializer: initializer, annotation: property.typeAnnotation)))
                instance.properties[property.name] = box
                continue
            }
            if let initializer = property.initializer {
                // Static context: property initializers may reference the
                // type's own statics bare (`= Timer.publish(every:
                // autoScrollDuration, …)`).
                do {
                    value = try resolveAnnotated(
                        try evaluate(initializer, in: selfEnvironment(.type(symbol))),
                        annotation: property.typeAnnotation
                    )
                } catch is InterpretedThrow {
                    // A default whose construction THROWS headlessly (real
                    // resources exist on device) reads unknowable.
                    value = .native(ChainedImplicitCall(
                        base: .implicitMember("default"), member: property.name,
                        arguments: CallArguments()))
                }
            }
            if case .void = value, property.wrapper == .state {
                // State-like wrappers whose default lives elsewhere
                // (@Default(.key) — Defaults package): fresh identity.
                var seen: Set<String> = []
                value = (try? synthesizedFreshValue(
                    typeName: property.typeAnnotation?.trimmedDescription ?? "",
                    seen: &seen)) ?? .nilValue
            }
            let box = Box(value)
            if notifying.contains(property.name) {
                // @Published (or @Observable-tracked) mutation → model signal.
                let signal = instance.changeSignal
                box.onChange = { signal.fire() }
            }
            switch property.wrapper {
            case .state, .stateObject:
                if persistentViewState, symbol.conformsToView, let site = node?.id {
                    let key = ViewStateKey(
                        site: site, type: symbol.name, property: property.name,
                        salt: viewIdentitySalts.joined(separator: "/"))
                    if Self.traceStateCells, property.name == "viewModel" || property.name == "fetcher" {
                        Swift.print("   ⌘ \(symbol.name).\(property.name) idx=\(site.indexInTree) salt=[\(key.salt)] \(viewStateCells[key] != nil ? "HIT" : "miss") src=\(node?.description.replacingOccurrences(of: "\n", with: " ").prefix(70) ?? "")")
                    }
                    if let existing = viewStateCells[key] {
                        instance.stateBoxes[property.name] = existing
                    } else {
                        viewStateCells[key] = box
                        instance.stateBoxes[property.name] = box
                    }
                } else {
                    if Self.traceStateCells, property.name == "viewModel" || property.name == "fetcher" {
                        Swift.print("   ⌘ \(symbol.name).\(property.name) NO-SITE persistent=\(persistentViewState) view=\(symbol.conformsToView)")
                    }
                    instance.stateBoxes[property.name] = box
                }
            default:
                instance.properties[property.name] = box
            }
        }

        // Declared inits win when one FITS and isn't already running (a
        // convenience init delegating to itself would recurse forever);
        // otherwise property-shaped labels bind MEMBERWISE — extension
        // inits don't suppress the memberwise init (SeparatorHStack's
        // closure-taking convenience delegates to the synthesized
        // value-taking form).
        let available = symbol.initializers.filter { !activeInitializers.contains($0.id) }
        let strictChoice = chooseInitializerStrict(from: available, for: args)
        var memberwise = symbol.initializers.isEmpty
        if !memberwise, strictChoice == nil {
            let propertyNames = Set(inheritedStoredProperties(of: symbol).map(\.name))
            let labels = args.arguments.compactMap(\.label)
            if !labels.isEmpty, labels.allSatisfy({ propertyNames.contains($0) }) {
                memberwise = true
            }
        }
        if memberwise {
            var assigned = Set<String>()
            // Labeled arguments claim their properties FIRST, so an unlabeled
            // trailing closure can't steal a property that a later labeled
            // trailing names (`CustomButton(tint:) { content } action: {…}`).
            for argument in args.arguments {
                guard let label = argument.label else { continue }
                guard let property = symbol.storedProperty(named: label),
                      let box = instance.box(for: label) else {
                    // Host-superclass classes (class RainFall: SKScene)
                    // inherit their initializers: unmatched labeled
                    // arguments bind as properties so later reads
                    // (`size` in sceneDidLoad) see the passed values.
                    if let superName = symbol.superclassName, !isInterpretedType(superName) {
                        instance.properties[label] = Box(argument.value)
                        assigned.insert(label)
                        continue
                    }
                    let message = "argument '\(label)' doesn't match a stored property of '\(symbol.name)'"
                    if let node { throw error(node, message) }
                    throw RuntimeError(message: message)
                }
                assigned.insert(label)
                if property.wrapper == .binding,
                   case .host(let any) = argument.value, let stub = any as? BindingStub {
                    instance.properties[label] = stub.box
                } else if property.wrapper == .binding,
                          case .host(let any) = argument.value,
                          let call = any as? ImplicitMemberCall, call.name == "constant" {
                    // `.constant("")` — a binding to a fixed value.
                    instance.properties[label] = Box(try resolveAnnotated(
                        call.arguments.positional(0) ?? .void,
                        annotation: property.typeAnnotation))
                } else if let closure = argument.value.closureValue,
                          property.isBuilderClosure,
                          !(property.typeAnnotation?.trimmedDescription.contains("->") ?? false) {
                    // Labeled trailing onto a builder property.
                    box.value = try builderValue(for: property, closure: closure)
                } else {
                    box.value = try resolveAnnotated(argument.value, annotation: property.typeAnnotation)
                }
            }
            for argument in args.arguments where argument.label == nil {
                if argument.value.closureValue != nil {
                    // Unlabeled trailing closure → FIRST unassigned
                    // closure-shaped stored property (SE-0286 forward scan);
                    // @ViewBuilder properties store the BUILT view (matching
                    // Swift's synthesized memberwise + builder init).
                    // `TagLayout(spacing: 10) { … }` — Layout containers
                    // take trailing content; children stash for rendering
                    // (the custom layout math doesn't run — documented).
                    if symbol.conformsToLayout,
                       !symbol.storedProperties.contains(where: { !assigned.contains($0.name) && $0.acceptsTrailingClosure }) {
                        let closure = argument.value.closureValue!
                        let children = try callBuilderClosure(closure, arguments: [])
                        instance.properties[StructSymbol.layoutChildrenKey] = Box(.native(children))
                        continue
                    }
                    guard let property = symbol.storedProperties.first(where: {
                        !assigned.contains($0.name) && $0.acceptsTrailingClosure
                    }), let box = instance.box(for: property.name) else {
                        let message = "trailing closure doesn't match a closure property of '\(symbol.name)'"
                        if let node { throw error(node, message) }
                        throw RuntimeError(message: message)
                    }
                    assigned.insert(property.name)
                    let functionTyped = property.typeAnnotation?.trimmedDescription.contains("->") ?? false
                    if property.isBuilderClosure && !functionTyped {
                        // Builder property — build now (array or grouped views).
                        let closure = argument.value.closureValue!
                        box.value = try builderValue(for: property, closure: closure)
                    } else {
                        // `var content: (CGSize) -> Content` (builder or not) —
                        // store the closure; the body calls it with arguments.
                        box.value = argument.value
                    }
                } else {
                    let message = "argument '_' doesn't match a stored property of '\(symbol.name)'"
                    if let node { throw error(node, message) }
                    throw RuntimeError(message: message)
                }
            }
        } else {
            if strictChoice == nil,
               !args.arguments.isEmpty,
               registry?.constructor(named: symbol.name) != nil {
                // No init fits and a HOST type shares the name (protobuf's
                // `struct Link` vs SwiftUI.Link): real Swift overload-
                // resolves across modules — the binding error routes the
                // caller's registry retry.
                let message = "argument '\(args.arguments.first?.label ?? "_")' doesn't match a stored property of '\(symbol.name)'"
                if let node { throw error(node, message) }
                throw RuntimeError(message: message)
            }
            return try runInitializer(
                strictChoice ?? chooseInitializer(from: symbol.initializers, for: args),
                on: instance, args: args, node: node)
        }
        return .instance(instance)
    }

    /// Sentinel unwound when a DELEGATED failable init returns nil: the
    /// enclosing init fails too (real init-delegation semantics).
    static let initFailedSentinel = "__delegated_init_failed__"

    /// Run one initializer body with `self` bound to the instance — used
    /// by instantiate and by `self.init(…)` delegation. Returns the FINAL
    /// self: struct inits may reassign it (`self = decoded`), and the
    /// caller must hand back that value, not the seed instance.
    @discardableResult
    func runInitializer(
        _ chosen: InitializerDeclSyntax, on instance: Instance,
        args: CallArguments, node: Syntax?
    ) throws -> RuntimeValue {
        guard let body = chosen.body else {
            throw RuntimeError(message: "init of '\(instance.symbol.name)' has no body")
        }
        let inserted = activeInitializers.insert(chosen.id).inserted
        defer { if inserted { activeInitializers.remove(chosen.id) } }
        let instanceKey = ObjectIdentifier(instance)
        let instanceInserted = initializingInstances.insert(instanceKey).inserted
        defer { if instanceInserted { initializingInstances.remove(instanceKey) } }
        let parameters = initializerMetadata(for: chosen).parameters
        let initEnv = selfEnvironment(.instance(instance))
        let closure = ClosureValue(
            parameters: parameters,
            body: body.statements,
            captured: initEnv
        )
        let outcome: RuntimeValue
        do {
            outcome = try callWithArguments(closure, args: args, node: node)
        } catch let failure as RuntimeError where failure.message == Self.initFailedSentinel {
            return .nilValue // a delegated failable init said no
        }
        if chosen.optionalMark != nil, outcome.isNil {
            return .nilValue // failable init: `return nil` means NO value
        }
        if case .instance(let final)? = initEnv.lookup("self"), final !== instance {
            return .instance(final) // `self = other` reassigned the value
        }
        return .instance(instance)
    }

    /// Overloaded methods pick by call shape; nil when nothing fits.
    func chooseFunction(from candidates: [FunctionDeclSyntax], for args: CallArguments) -> FunctionDeclSyntax? {
        let arguments = ArgumentShape(args)
        for candidate in candidates {
            if functionMetadata(for: candidate).shape.matches(arguments) {
                return candidate
            }
        }
        return nil
    }

    /// `init(from decoder:)` / `init(coder:)` — only decoders reach these.
    static func isCodableInit(_ initializer: InitializerDeclSyntax) -> Bool {
        let params = initializer.signature.parameterClause.parameters
        guard params.count == 1, let only = params.first else { return false }
        let label = only.firstName.text
        let type = only.type.trimmedDescription
        return (label == "from" && type.contains("Decoder"))
            || (label == "coder" && type.contains("Coder"))
    }

    func chooseInitializer(from initializers: [InitializerDeclSyntax], for args: CallArguments) -> InitializerDeclSyntax {
        chooseInitializerStrict(from: initializers, for: args)
            ?? initializers.first { !Self.isCodableInit($0) }
            ?? initializers[0]
    }

    /// Shape-matching only — nil when NO candidate fits (callers decide
    /// whether to fall back or treat the call as an inherited init).
    func chooseInitializerStrict(from initializers: [InitializerDeclSyntax], for args: CallArguments) -> InitializerDeclSyntax? {
        let arguments = ArgumentShape(args)
        var fits: [InitializerDeclSyntax] = []
        for candidate in initializers {
            // Shape match: every arg label exists, every required label is
            // provided (trailing closures may fill one), and positional args
            // have `_` slots — `Pubkey(data)` must NOT pick init?(hex:).
            // Only UNLABELED trailing closures can fill missing required
            // labels (labeled trailings already matched by name) — the
            // binder gives them to the LAST unbound slot, so selection
            // must not over-promise (IceSection's 5-param designated init
            // vs its 4-param delegation).
            if initializerMetadata(for: candidate).shape.matches(arguments) {
                fits.append(candidate)
            }
        }
        guard fits.count > 1 else { return fits.first }
        // Same-labeled overloads (`init(_ source:)` vs `init(_ sources:
        // [X])`; closure-taking convenience inits delegating to
        // value-taking designated ones): the argument's ARRAY-ness and
        // CLOSURE-ness pick the matching annotations — real overload
        // resolution's type dimension, coarsely.
        func typeScore(_ candidate: InitializerDeclSyntax) -> Int {
            var score = 0
            var positionalIndex = 0
            for parameter in initializerMetadata(for: candidate).parameters {
                let value: RuntimeValue?
                if let label = parameter.label {
                    value = args.labeled(label)
                } else {
                    value = args.positional(positionalIndex)
                    positionalIndex += 1
                }
                guard let value else { continue }
                let annotation = parameter.typeName ?? ""
                let wantsArray = annotation.hasPrefix("[") && !annotation.contains(":")
                let wantsClosure = annotation.contains("->")
                let isArray = value.arrayValue != nil
                let isClosure = value.closureValue != nil
                score += (wantsArray == isArray) ? 1 : -1
                score += (wantsClosure == isClosure) ? 1 : -1
            }
            return score
        }
        var best = fits[0]
        var bestScore = typeScore(best)
        for candidate in fits.dropFirst() {
            let score = typeScore(candidate)
            if score > bestScore { best = candidate; bestScore = score }
        }
        return best
    }

    /// Evaluate an instance's `body` computed property in ViewBuilder mode.
    /// Multiple top-level views are grouped by the registry (TupleView stand-in).
    public func evaluateBody(of instance: Instance) throws -> RuntimeValue {
        steps = 0
        guard let computed = bodyProperty(of: instance.symbol) else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no body property")
        }
        let views = try collectBuilderViews(computed.accessor, in: selfEnvironment(.instance(instance)))
        return try groupViews(views)
    }

    /// Call an instance method with positional arguments — the bridge's entry
    /// point for protocol requirements it hosts (a Shape's `path(in:)`).
    public func callMethod(named name: String, on instance: Instance, arguments: [RuntimeValue]) throws -> RuntimeValue {
        guard let member = try instanceMember(name, on: instance),
              let closure = member.closureValue else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no method '\(name)'")
        }
        return try callClosure(closure, arguments: arguments)
    }

    /// Fill `@EnvironmentObject` properties from ambient models (keyed by type
    /// name). The SwiftUI bridge reads the models off the real Environment;
    /// headless harnesses thread them down the trace tree. When no ambient
    /// model exists (the App shell that would inject it never runs), a fresh
    /// instance of the type is synthesized once and reused — the same
    /// fresh-store doctrine as @Query.
    public func injectEnvironmentObjects(into instance: Instance, models: [String: Instance]) throws {
        for property in instance.symbol.storedProperties {
            // Observation's TYPED environment (`@Environment(MastodonClient
            // .self) var client`) resolves from the same ambient-models
            // dict — `.environment(model)` injections key by symbol name.
            // Keypath keys (`\.dismiss`) are lowercase and stay with
            // injectEnvironmentValues.
            var typeName: String
            var typedEnvironment = false
            switch property.wrapper {
            case .environmentObject:
                typeName = property.typeAnnotation?.trimmedDescription ?? ""
            case .environment(let name) where name.first?.isUppercase == true:
                typeName = name
                typedEnvironment = true
            default:
                continue
            }
            if let generic = typeName.firstIndex(of: "<") {
                typeName = String(typeName[..<generic]) // generics drop everywhere
            }
            // Typed-environment properties fill ONLY from what the app
            // actually injected (or an earlier synthesis) — a missing
            // injection stays an absorbed read (on device it would crash;
            // headlessly the fresh canvas absorbs), never a fresh instance
            // with side-effecting init.
            if typedEnvironment, models[typeName] == nil,
               synthesizedEnvironmentModels[typeName] == nil {
                continue
            }
            let model: Instance
            if let ambient = models[typeName] {
                model = ambient
            } else if let synthesized = synthesizedEnvironmentModels[typeName] {
                model = synthesized
            } else if case .type(let symbol)? = globals.lookup(typeName),
                      case .instance(let fresh) = try instantiateRoot(symbol) {
                // Fresh model with FRESH parameter values — the same
                // synthesis roots get (inits with required params work).
                synthesizedEnvironmentModels[typeName] = fresh
                model = fresh
            } else if assumesCompiledImports {
                // UNMERGED model types (an external package's Updater): the
                // device's App shell injected something real — an absorbing
                // bag stands in (reads chain, writes accepted).
                instance.box(for: property.name)?.value = registry?.absorbedCValue(named: typeName)
                    ?? .native(ChainedImplicitCall(
                        base: .implicitMember(typeName), member: "shared", arguments: CallArguments()))
                continue
            } else {
                throw RuntimeError(message: "no ObservableObject of type '\(typeName)' in the environment — inject it with .environmentObject(_:)")
            }
            instance.box(for: property.name)?.value = .instance(model)
        }
    }

    /// Fill `@Environment(\.key)` properties from a key→value table (the
    /// bridge reads real values off SwiftUI's Environment; headless harnesses
    /// inject honest defaults). Unknown keys are left untouched.
    public func injectEnvironmentValues(into instance: Instance, values: [String: RuntimeValue]) {
        for property in instance.symbol.storedProperties {
            guard case .environment(let key) = property.wrapper else { continue }
            if let value = values[key] {
                instance.box(for: property.name)?.value = value
                continue
            }
            // CUSTOM environment keys (extension EnvironmentValues { @Entry
            // var indentationLevel: UInt = 0 }): read the extension's OWN
            // declared default when present; otherwise the fresh identity
            // of the annotation (false/0/""/nil) — the fresh-canvas reading.
            if let box = instance.box(for: property.name), case .void = box.value {
                if let envExtension = hostExtensionSymbols["EnvironmentValues"],
                   let declared = envExtension.storedProperty(named: key),
                   let initializer = declared.initializer,
                   let value = try? evaluate(initializer, in: globals) {
                    box.value = (try? resolveAnnotated(value, annotation: declared.typeAnnotation)) ?? value
                    continue
                }
                let typeName = property.typeAnnotation?.trimmedDescription ?? ""
                var seen: Set<String> = []
                box.value = (try? synthesizedFreshValue(typeName: typeName, seen: &seen)) ?? .nilValue
            }
        }
    }

    /// The struct to render when the program doesn't end in an explicit view
    /// expression: `ContentView` if present, then `Main`, then the first
    /// View-conforming struct in declaration order.
    /// Instantiate a root view for standalone verification: required
    /// parameters (un-defaulted stored properties, or a custom init's
    /// parameters) receive synthesized FRESH values — the fresh-state
    /// doctrine applied to view parameters.
    public func instantiateRoot(_ symbol: StructSymbol) throws -> RuntimeValue {
        var seen: Set<String> = [symbol.name]
        let args = try synthesizedArguments(for: symbol, seen: &seen)
        return try instantiate(symbol, with: args)
    }

    /// A property typed by one of the OWNER's generic parameters: fresh
    /// empty view for View-constrained params (registry-backed), otherwise
    /// an unknowable chain — never a same-named concrete type.
    private func synthesizedGenericValue(constraint: String, parameter: String) -> RuntimeValue {
        if constraint.contains("View"), let ctor = registry?.constructor(named: "EmptyView"),
           let view = try? ctor.invoke(CallArguments(arguments: []), self) {
            return view
        }
        return .native(ChainedImplicitCall(
            base: .implicitMember("generic"), member: parameter, arguments: CallArguments()))
    }

    private func synthesizedArguments(for symbol: StructSymbol, seen: inout Set<String>) throws -> CallArguments {
        var arguments: [CallArguments.Argument] = []
        // Prefer a NON-failable, NON-Codable init: synthesized fresh
        // arguments rarely satisfy `init?` guards, and `init(from:
        // decoder)` is only ever reached through real decoders.
        let preferred = symbol.initializers.first {
            $0.optionalMark == nil && !Self.isCodableInit($0)
        } ?? symbol.initializers.first { !Self.isCodableInit($0) }
            ?? symbol.initializers.first
        if let initializer = preferred {
            for param in initializer.signature.parameterClause.parameters
            where param.defaultValue == nil {
                let label = param.firstName.text
                let typeName = param.type.trimmedDescription
                let value: RuntimeValue
                if let constraint = symbol.genericParameters[typeName] {
                    value = synthesizedGenericValue(constraint: constraint, parameter: typeName)
                } else {
                    value = try synthesizedFreshValue(typeName: typeName, owner: symbol, seen: &seen)
                }
                arguments.append(.init(label: label == "_" ? nil : label, value: value))
            }
        } else {
            for property in symbol.storedProperties
            where property.initializer == nil && !property.isBuilderClosure {
                let typeName = property.typeAnnotation?.trimmedDescription ?? ""
                switch property.wrapper {
                case .none:
                    if let constraint = symbol.genericParameters[typeName] {
                        arguments.append(.init(
                            label: property.name,
                            value: synthesizedGenericValue(constraint: constraint, parameter: typeName)))
                        continue
                    }
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: typeName, owner: symbol, seen: &seen)))
                case .binding:
                    // A standalone root has no parent to pass bindings —
                    // synthesize one over the inner type's fresh value.
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: "Binding<\(typeName)>", seen: &seen)))
                case .observedObject, .stateObject:
                    // Fresh model per the missing-environment-object doctrine
                    // (initializer-less wrappers only — the where clause).
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: typeName, owner: symbol, seen: &seen)))
                default:
                    break // @State/@StateObject etc. default independently
                }
            }
        }
        return CallArguments(arguments: arguments)
    }

    /// Owner-scoped fresh value: the OWNER's nested types win over
    /// same-named globals (each view's `enum Location` is its own).
    func synthesizedFreshValue(
        typeName rawName: String, owner: StructSymbol, seen: inout Set<String>
    ) throws -> RuntimeValue {
        let typeName = rawName.trimmingCharacters(in: .whitespaces)
        if !typeName.hasSuffix("?"), !typeName.hasSuffix("!") {
            if let enumSymbol = enumSymbols["\(owner.name).\(typeName)"],
               let first = enumSymbol.cases.first(where: { !$0.hasAssociatedValues }) {
                return .enumCase(EnumCaseValue(symbol: enumSymbol, name: first.name))
            }
            if case .type(let nested)? = owner.nestedTypes[typeName], !seen.contains(nested.name) {
                seen.insert(nested.name)
                defer { seen.remove(nested.name) }
                if let args = try? synthesizedArguments(for: nested, seen: &seen),
                   let built = try? instantiate(nested, with: args), !built.isNil {
                    return built
                }
            }
        }
        return try synthesizedFreshValue(typeName: rawName, seen: &seen)
    }

    /// The fresh value of a type: identity for primitives, empty for
    /// collections, nil for optionals, recursive fresh instances for
    /// interpreted types, and an unknowable chain (absorbs everywhere)
    /// for host/generic types.
    func synthesizedFreshValue(typeName rawName: String, seen: inout Set<String>) throws -> RuntimeValue {
        var typeName = rawName.trimmingCharacters(in: .whitespaces)
        if typeName.hasSuffix("?") || typeName.hasSuffix("!") { return .nilValue }
        if typeName.hasPrefix("[") { // arrays AND dictionaries start empty
            return typeName.contains(":") ? .native(DictValue()) : .native([RuntimeValue]())
        }
        if typeName.contains("->") {
            return .hostFunction(HostFunction(name: "synthesized") { _, _ in .void })
        }
        if typeName.hasPrefix("Binding<"), typeName.hasSuffix(">") {
            let inner = String(typeName.dropFirst("Binding<".count).dropLast())
            let value = try synthesizedFreshValue(typeName: inner, seen: &seen)
            return .native(BindingStub(box: Box(value)))
        }
        switch typeName {
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8",
             "UInt16", "UInt32", "UInt64": return .native(0)
        case "String", "Character": return .native("")
        case "Bool": return .native(false)
        case "Date": return .native(Date())
        case "Data": return .native(Data())
        default: break
        }
        if Self.doubleFamilyTypeNames.contains(typeName) { return .native(0.0) }
        if let generic = typeName.firstIndex(of: "<") {
            typeName = String(typeName[..<generic]) // Store<A, B> → Store
        }
        if !seen.contains(typeName) {
            seen.insert(typeName)
            defer { seen.remove(typeName) }
            if case .type(let nested)? = globals.lookup(typeName) {
                // A throwing/guarded init that rejects fresh inputs means
                // the value is unobtainable headlessly — fall through to
                // the unknowable chain instead of failing the whole unit.
                if let args = try? synthesizedArguments(for: nested, seen: &seen),
                   let built = try? instantiate(nested, with: args),
                   !built.isNil {
                    return built
                }
            }
            if let enumSymbol = enumSymbols[typeName],
               let first = enumSymbol.cases.first(where: { !$0.hasAssociatedValues }) {
                return .enumCase(EnumCaseValue(symbol: enumSymbol, name: first.name))
            }
        }
        // Host/generic/cyclic types: an unknowable chain — reads chain,
        // bools read false, numerics zero, iteration empty.
        return .native(ChainedImplicitCall(
            base: .implicitMember("synthesized"), member: typeName, arguments: CallArguments()))
    }

    public func rootViewSymbol() -> StructSymbol? {
        let candidates = structSymbols.filter(\.conformsToView)
        // The app's OWN declared root wins: the first View constructed in an
        // @main App body, or the one a delegate hosts via
        // UIHostingController(rootView:)/NSHostingController — name-based
        // heuristics are the fallback, not the first resort.
        if let declared = declaredRootViewName(),
           let symbol = candidates.first(where: { $0.name == declared }) {
            return symbol
        }
        return candidates.first { $0.name == "ContentView" }
            ?? candidates.first { $0.name == "Main" }
            ?? candidates.first
    }

    /// Whether a name resolves to an interpreted struct/class/enum symbol
    /// (as opposed to a host framework type like SKScene).
    func isInterpretedType(_ name: String) -> Bool {
        if case .type? = globals.lookup(name) { return true }
        if case .enumType? = globals.lookup(name) { return true }
        return false
    }

    static let doubleFamilyTypeNames: Set<String> = [
        "Double", "CGFloat", "Float", "TimeInterval", "Float32", "Float64",
    ]

    func selfEnvironment(_ selfValue: RuntimeValue) -> Environment {
        let env = Environment(parent: globals)
        env.define("self", selfValue)
        return env
    }

    /// A type annotation turns a bare `.member` (or `.member(payload)`) into
    /// the annotated type's case, `.init`, or static member — the dynamic
    /// stand-in for type context. `[Type]` annotations resolve array elements.
    func resolveAnnotated(_ value: RuntimeValue, annotation: TypeSyntax?) throws -> RuntimeValue {
        guard let annotation else { return value }
        return try resolveAnnotated(value, typeName: annotation.trimmedDescription)
    }

    func resolveAnnotated(
        _ value: RuntimeValue, parameter: ClosureValue.Parameter
    ) throws -> RuntimeValue {
        guard let typeName = parameter.typeName else { return value }
        return try resolveAnnotated(value, typeName: typeName)
    }

    func resolveAnnotated(_ value: RuntimeValue, typeName rawName: String) throws -> RuntimeValue {
        // Cyclic marker graphs (lazy-global cycles can weave a chain whose
        // base reaches itself) must not recurse the native stack to death:
        // past any plausible nesting the value stays an absorbing marker.
        resolveAnnotatedDepth += 1
        defer { resolveAnnotatedDepth -= 1 }
        guard resolveAnnotatedDepth < 64 else { return value }
        var typeName = rawName.trimmingCharacters(in: .whitespaces)
        if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }

        // `(hrp: String, data: Data)` annotations LABEL positional tuple
        // literals so `decoded.hrp` member reads work.
        if typeName.hasPrefix("("), typeName.hasSuffix(")"), typeName.contains(":"),
           let tuple = value.tupleValue, tuple.labels.allSatisfy({ $0 == nil }) {
            let inner = String(typeName.dropFirst().dropLast())
            var depth = 0
            var parts: [String] = []
            var current = ""
            for ch in inner {
                if ch == "(" || ch == "<" || ch == "[" { depth += 1 }
                if ch == ")" || ch == ">" || ch == "]" { depth -= 1 }
                if ch == ",", depth == 0 {
                    parts.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            parts.append(current)
            if parts.count == tuple.values.count {
                let labels = parts.map { part -> String? in
                    guard let colon = part.firstIndex(of: ":") else { return nil }
                    let label = part[..<colon].trimmingCharacters(in: .whitespaces)
                    return label.isEmpty || label.contains(" ") ? nil : label
                }
                if labels.contains(where: { $0 != nil }) {
                    return .native(TupleValue(labels: labels, values: tuple.values))
                }
            }
        }

        // Double-family storage holds doubles: `var offset: CGFloat = 0`
        // stores 0.0, so division/interpolation behave like compiled Swift
        // (20 / offset is IEEE infinity, not an Int-division trap).
        if Self.doubleFamilyTypeNames.contains(typeName), let i = value.intValue {
            return .native(Double(i))
        }

        // `[Item]` — resolve each element against the element type.
        if typeName.hasPrefix("["), typeName.hasSuffix("]"), !typeName.contains(":"),
           let array = value.arrayValue {
            let elementType = String(typeName.dropFirst().dropLast())
            return .native(try array.map { try resolveAnnotated($0, typeName: elementType) })
        }

        if let symbol = enumSymbols[typeName] {
            if case .implicitMember(let name) = value,
               let info = symbol.caseInfo(named: name), !info.hasAssociatedValues {
                return .enumCase(EnumCaseValue(symbol: symbol, name: name))
            }
            // `self = .init(rawValue: n)!` inside enum inits — the marker
            // resolves through the raw-value initializer in type context.
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               call.name == "init", call.arguments.arguments.count == 1,
               let raw = call.arguments.labeled("rawValue") {
                return symbol.cases
                    .first { (try? Builtins.areEqual($0.rawValue, raw)) == true }
                    .map { RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name)) }
                    ?? .nilValue
            }
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               let info = symbol.caseInfo(named: call.name), info.hasAssociatedValues {
                return .enumCase(EnumCaseValue(
                    symbol: symbol,
                    name: call.name,
                    associated: call.arguments.arguments.map(\.value)
                ))
            }
            return value
        }

        // User structs/classes: `= .init(...)`, static factories, static values.
        if case .type(let symbol)? = globals.lookup(typeName) {
            if case .host(let any) = value, let call = any as? ImplicitMemberCall {
                if call.name == "init" {
                    return try instantiate(symbol, with: call.arguments)
                }
                if let overloads = symbol.staticMethods[call.name],
                   let method = chooseFunction(from: overloads, for: call.arguments) ?? overloads.first,
                   let body = method.body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.type(symbol)))
                    return try callWithArguments(closure, args: call.arguments, node: nil)
                }
            }
            if case .implicitMember(let name) = value,
               let staticValue = try staticMember(name, of: symbol) {
                return staticValue
            }
            return value
        }

        // Host-type annotations: `: Date = .init()`, `: CGSize = .init(…)`,
        // `.now`-style statics served by the bridge.
        if case .host(let any) = value, let call = any as? ImplicitMemberCall {
            if call.name == "init" {
                if let ctor = registry?.hostObjectConstructor(named: typeName) {
                    return try ctor.invoke(call.arguments, self)
                }
                if case .hostFunction(let builtin)? = globals.lookup(typeName) {
                    return try builtin.invoke(call.arguments, self)
                }
            }
            if let member = registry?.hostMember(call.name, on: HostTypeMarker(name: typeName)) {
                if case .hostFunction(let function) = member {
                    return try function.invoke(call.arguments, self)
                }
                return member
            }
        }
        if case .implicitMember(let memberName) = value,
           let member = registry?.hostMember(memberName, on: HostTypeMarker(name: typeName)) {
            return member
        }
        // `.now.startOfMonth` — chained markers resolve their base against
        // the type, then the member (host natives and user extensions both).
        if case .host(let any) = value, let chained = any as? ChainedImplicitCall {
            let resolvedBase = try resolveAnnotated(chained.base, typeName: typeName)
            let stillMarker: Bool = {
                if case .implicitMember = resolvedBase { return true }
                if case .host(let inner) = resolvedBase,
                   inner is ImplicitMemberCall || inner is ChainedImplicitCall { return true }
                return false
            }()
            if !stillMarker {
                let anchor = ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier("resolvedChainBase")))
                let member = try accessMember(chained.member, on: resolvedBase, node: anchor, env: globals)
                switch member {
                case .closure(let closure):
                    return try callWithArguments(closure, args: chained.arguments, node: nil)
                case .hostFunction(let function):
                    return try function.invoke(chained.arguments, self)
                default:
                    return member
                }
            }
        }

        // User extensions of host types add statics too:
        // `extension Date { static var currentMonth: Date }` resolves
        // `: Date = .currentMonth` (and `.createDate(…)` factories).
        if let hostSymbol = hostExtensionSymbols[typeName] {
            if case .implicitMember(let memberName) = value,
               let staticValue = try staticMember(memberName, of: hostSymbol) {
                return staticValue
            }
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               let overloads = hostSymbol.staticMethods[call.name],
               let method = chooseFunction(from: overloads, for: call.arguments) ?? overloads.first,
               let body = method.body {
                let closure = makeFunctionClosure(
                    method, body: body, captured: selfEnvironment(.type(hostSymbol)))
                return try callWithArguments(closure, args: call.arguments, node: nil)
            }
        }
        return value
    }

    // MARK: - Global builtins

    private func defineGlobalBuiltins() {
        func define(_ name: String, _ invoke: @escaping @MainActor (CallArguments, EvalContext) throws -> RuntimeValue) {
            globals.define(name, .hostFunction(HostFunction(name: name, invoke: invoke)))
        }
        define("print") { args, _ in
            Swift.print(args.arguments.map { $0.value.stringValue ?? $0.value.stringified }.joined(separator: " "))
            return .void
        }
        define("abs") { args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: "abs needs a number") }
            if let i = value.intValue { return .native(Swift.abs(i)) }
            if let d = value.doubleValue { return .native(Swift.abs(d)) }
            throw RuntimeError(message: "abs needs a number")
        }
        define("type") { args, _ in
            // `type(of: endpoint)` — the DYNAMIC metatype, comparable with
            // `X.self` (MastodonClient branches its URL path on it).
            guard let value = args.labeled("of") else {
                throw RuntimeError(message: "type(of:) needs a value")
            }
            switch value {
            case .instance(let instance): return .type(instance.symbol)
            case .enumCase(let enumCase): return .enumType(enumCase.symbol)
            case .type, .enumType: return value
            case .int: return .native(HostTypeMarker(name: "Int"))
            case .double: return .native(HostTypeMarker(name: "Double"))
            case .bool: return .native(HostTypeMarker(name: "Bool"))
            case .host(let any):
                return .native(HostTypeMarker(name: String(describing: Swift.type(of: any))))
            default:
                return .native(HostTypeMarker(name: "Void"))
            }
        }
        func defineUnaryMath(_ name: String, _ op: @escaping (Double) -> Double) {
            define(name) { args, _ in
                guard let d = args.positional(0)?.doubleValue else {
                    throw RuntimeError(message: "\(name) needs a number")
                }
                return .native(op(d))
            }
        }
        defineUnaryMath("round") { $0.rounded() }
        defineUnaryMath("floor") { $0.rounded(.down) }
        defineUnaryMath("ceil") { $0.rounded(.up) }
        defineUnaryMath("sqrt") { $0.squareRoot() }
        defineUnaryMath("sin") { Foundation.sin($0) }
        defineUnaryMath("cos") { Foundation.cos($0) }
        defineUnaryMath("tan") { Foundation.tan($0) }
        defineUnaryMath("asin") { Foundation.asin($0) }
        defineUnaryMath("acos") { Foundation.acos($0) }
        defineUnaryMath("atan") { Foundation.atan($0) }
        defineUnaryMath("log") { Foundation.log($0) }
        defineUnaryMath("log2") { Foundation.log2($0) }
        defineUnaryMath("exp") { Foundation.exp($0) }
        define("atan2") { args, _ in
            guard let y = args.positional(0)?.doubleValue, let x = args.positional(1)?.doubleValue else {
                throw RuntimeError(message: "atan2 needs two numbers")
            }
            return .native(Foundation.atan2(y, x))
        }
        define("hypot") { args, _ in
            guard let x = args.positional(0)?.doubleValue, let y = args.positional(1)?.doubleValue else {
                throw RuntimeError(message: "hypot needs two numbers")
            }
            return .native(Foundation.hypot(x, y))
        }
        define("pow") { args, _ in
            guard let base = args.positional(0)?.doubleValue, let exponent = args.positional(1)?.doubleValue else {
                throw RuntimeError(message: "pow needs two numbers")
            }
            return .native(Foundation.pow(base, exponent))
        }
        define("min") { args, _ in
            try Self.extremum(args, op: "<")
        }
        define("max") { args, _ in
            try Self.extremum(args, op: ">")
        }
        define("String") { args, _ in
            if let format = args.labeled("format")?.stringValue {
                // `String(format: "%.1f", per)` — real formatting; remaining
                // positionals map to CVarArgs.
                let varargs: [CVarArg] = args.arguments.dropFirst().compactMap { argument in
                    if let i = argument.value.intValue { return i }
                    if let d = argument.value.doubleValue { return d }
                    if let s = argument.value.stringValue { return s }
                    return nil
                }
                return .native(Swift.String(format: format, arguments: varargs))
            }
            if let repeating = args.labeled("repeating")?.stringValue, let count = args.labeled("count")?.intValue {
                return .native(Swift.String(repeating: repeating, count: Swift.max(0, count)))
            }
            if let bytes = args.labeled("bytes") {
                // String(bytes: data, encoding: .ascii) — real decode; NUL
                // padding trims (C buffers).
                if case .host(let any) = bytes, let data = any as? Data {
                    let text = String(decoding: data, as: UTF8.self)
                    return .native(String(text.prefix(while: { $0 != "\0" })))
                }
                if let text = bytes.stringValue { return .native(text) }
                return .nilValue
            }
            if args.labeled("cString") != nil || args.labeled("validatingUTF8") != nil {
                // C-string of an absorbed buffer reads empty (fresh).
                let value = args.labeled("cString") ?? args.labeled("validatingUTF8")
                return .native(value?.stringValue ?? "")
            }
            guard let value = args.positional(0) ?? args.labeled("describing") else { return .native("") }
            return .native(value.stringValue ?? value.stringified)
        }
        define("Int") { args, _ in
            guard let value = args.positional(0) ?? args.labeled("exactly") else { return .nilValue }
            if let i = value.intValue { return .native(i) }
            if let d = value.doubleValue {
                // Int(exactly:) is nil for fractional values — real semantics.
                if args.labeled("exactly") != nil, d != d.rounded(.towardZero) { return .nilValue }
                return .native(Int(d))
            }
            if let s = value.stringValue { return Int(s).map { RuntimeValue.native($0) } ?? .nilValue }
            // Numeric conversion of an unknowable reads the fresh state —
            // Int(player.currentTime.truncatingRemainder(…)) is 0, not nil.
            if let z = Builtins.absorbedNumeric(value) { return .native(Int(z.isFinite ? z : 0)) }
            return .nilValue
        }
        define("Double") { args, _ in
            guard let value = args.positional(0) ?? args.labeled("exactly") else { return .nilValue }
            if let d = value.doubleValue { return .native(d) }
            if let s = value.stringValue { return Double(s).map { RuntimeValue.native($0) } ?? .nilValue }
            if let z = Builtins.absorbedNumeric(value) { return .native(z) }
            return .nilValue
        }
        define("Float") { args, _ in
            // Our floating model is Double throughout.
            guard let value = args.positional(0) ?? args.labeled("exactly") else { return .nilValue }
            if let d = value.doubleValue { return .native(d) }
            if let s = value.stringValue { return Double(s).map { RuntimeValue.native($0) } ?? .nilValue }
            if let z = Builtins.absorbedNumeric(value) { return .native(z) }
            return .nilValue
        }
        define("CGFloat") { args, _ in
            // Our CGFloat model IS Double.
            let operand = args.positional(0) ?? args.labeled("exactly")
            if let d = operand?.doubleValue { return .native(d) }
            if let value = operand, let z = Builtins.absorbedNumeric(value) {
                return .native(z) // unknowables read fresh zero (iter-94 rule)
            }
            throw RuntimeError(message: "CGFloat needs a number")
        }
        define("Array") { args, _ in
            if let element = args.labeled("repeating"), let count = args.labeled("count")?.intValue {
                return .native([RuntimeValue](repeating: element, count: max(0, count)))
            }
            guard let value = args.positional(0) else { return .native([RuntimeValue]()) }
            if let range = value.rangeValue { return .native(range.map { RuntimeValue.native($0) }) }
            if let array = value.arrayValue { return .native(array) }
            // Array("abc") splits into characters (single-char strings,
            // our character model): Array(constant)[i] indexes real chars.
            if let s = value.stringValue {
                return .native(s.map { RuntimeValue.native(String($0)) })
            }
            return .native([value])
        }
        define("Set") { args, _ in
            // Array-backed set-lite: construction and iteration cover the
            // corpus (Set<AnyCancellable>() holders, Set(array) dedup-ish).
            if let array = args.positional(0)?.arrayValue {
                var seen: [RuntimeValue] = []
                for element in array where try !seen.contains(where: { try Builtins.areEqual($0, element) }) {
                    seen.append(element)
                }
                return .native(seen)
            }
            return .native([RuntimeValue]())
        }
        define("fatalError") { args, _ in
            let message = args.positional(0)?.stringValue ?? "fatalError"
            throw RuntimeError(message: "fatalError: \(message)", fatal: true)
        }
        define("preconditionFailure") { args, _ in
            let message = args.positional(0)?.stringValue ?? "preconditionFailure"
            throw RuntimeError(message: "preconditionFailure: \(message)", fatal: true)
        }
        define("assertionFailure") { args, _ in
            let message = args.positional(0)?.stringValue ?? "assertionFailure"
            throw RuntimeError(message: "assertionFailure: \(message)", fatal: true)
        }
        // assert/precondition describe DEVICE truths: concrete false traps,
        // unknowable (marker-fed) conditions assume a healthy device.
        for trap in ["assert", "precondition"] {
            define(trap) { args, _ in
                if let concrete = args.positional(0)?.boolValue,
                   !concrete {
                    let message = args.positional(1)?.stringValue ?? trap
                    throw RuntimeError(message: "\(trap) failed: \(message)", fatal: true)
                }
                return .void
            }
        }
        for intType in ["UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64"] {
            define(intType) { args, _ in
                // Fixed-width conversions: our integer model is Int.
                let value = args.labeled("truncatingIfNeeded") ?? args.labeled("clamping")
                    ?? args.labeled("bitPattern") ?? args.labeled("exactly") ?? args.positional(0)
                if let i = value?.intValue { return .native(i) }
                if let d = value?.doubleValue { return .native(Int(d)) }
                if let s = value?.stringValue { return Int(s).map { RuntimeValue.native($0) } ?? .nilValue }
                if let value, let z = Builtins.absorbedNumeric(value) { return .native(Int(z.isFinite ? z : 0)) }
                return .native(0)
            }
        }
        define("Range") { args, _ in
            // Range(nsRange, in: string) — real conversion. An unknowable
            // NSRange (marker text-parse results) honestly fails: nil, the
            // parse that found nothing.
            if let text = (args.labeled("in"))?.stringValue {
                if case .host(let any)? = args.positional(0), let ns = any as? NSRange {
                    return Range(ns, in: text).map { RuntimeValue.native($0) } ?? .nilValue
                }
                return .nilValue
            }
            return args.positional(0) ?? .nilValue
        }
        define("unsafeBitCast") { args, _ in
            // Bit-identity cast: the value passes through (casts are
            // optimistic everywhere in the interpreter).
            args.positional(0) ?? .void
        }
        define("UUID") { _, _ in .native(UUID()) }
        define("URL") { args, _ in
            // Real URL semantics: invalid strings are honestly nil.
            if let s = (args.labeled("string") ?? args.positional(0))?.stringValue {
                return URL(string: s).map { RuntimeValue.native($0) } ?? .nilValue
            }
            if let path = args.labeled("fileURLWithPath")?.stringValue {
                return .native(URL(fileURLWithPath: path))
            }
            // Unknowable string (host-constant markers like
            // UIApplication.openSettingsURLString): the URL is equally
            // unknowable but non-nil on device — the marker flows through.
            if let value = args.labeled("string") ?? args.positional(0), !value.isNil {
                return value
            }
            return .nilValue
        }
        define("Date") { args, _ in
            // Interval inits construct for real; the argless form is `now`.
            if let interval = args.labeled("timeIntervalSince1970")?.doubleValue {
                return .native(Date(timeIntervalSince1970: interval))
            }
            if let interval = args.labeled("timeIntervalSinceNow")?.doubleValue {
                return .native(Date(timeIntervalSinceNow: interval))
            }
            if let interval = args.labeled("timeIntervalSinceReferenceDate")?.doubleValue {
                return .native(Date(timeIntervalSinceReferenceDate: interval))
            }
            return .native(Date())
        }
    }

    private static func extremum(_ args: CallArguments, op: String) throws -> RuntimeValue {
        let values = args.arguments.map(\.value)
        guard var best = values.first else { throw RuntimeError(message: "min/max need arguments") }
        for value in values.dropFirst() {
            if try Builtins.binary(op, value, best).boolValue == true { best = value }
        }
        return best
    }

    // MARK: - Errors & budget

    func error(_ node: some SyntaxProtocol, _ message: String) -> RuntimeError {
        guard let location = locationConverter?.location(for: node.positionAfterSkippingLeadingTrivia) else {
            return RuntimeError(message: message)
        }
        return RuntimeError(message: message, line: location.line, column: location.column)
    }

    func tick(_ node: some SyntaxProtocol) throws {
        steps += 1
        if steps > stepBudget {
            let located = error(node, "evaluation budget exceeded (possible infinite loop)")
            throw RuntimeError(
                message: located.message, line: located.line, column: located.column,
                fatal: true, budgetTrip: true)
        }
    }
}

// MARK: - EvalContext (what gateways can call back into)

extension Interpreter: EvalContext {
    public func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        steps = 0 // fresh entry, e.g. a Button action invoked from the UI
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        return try callWithArguments(closure, args: args, node: nil)
    }

    /// Background work (`Task { … }` bodies). On device these run
    /// concurrently, so an INTENTIONALLY infinite loop (`while true {
    /// poll(); try? await Task.sleep }`) is legitimate there — it suspends
    /// and never blocks launch. Synchronously we give the body a bounded
    /// slice and PARK it when the slice is spent: execution stops quietly
    /// and the caller's own budget is untouched. Documented divergence:
    /// parked background tasks never resume.
    public func callBackgroundClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        let entrySteps = steps
        let slice = 20_000
        steps = max(0, stepBudget - slice)
        defer { steps = entrySteps }
        do {
            let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
            return try callWithArguments(closure, args: args, node: nil)
        } catch let error as RuntimeError where error.budgetTrip {
            return .void // parked
        }
    }

    public func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue] {
        let env = Environment(parent: closure.captured)
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        try bindParameters(of: closure, to: args, into: env, node: nil)
        return try collectBuilderViews(closure.body, in: env)
    }
}
