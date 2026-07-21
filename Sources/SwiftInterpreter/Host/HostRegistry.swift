/// Evaluated call arguments in source order: labeled args first, then the
/// trailing closure (label nil) and any additional trailing closures (labeled).
enum CallArgumentSourceProvenance: Equatable {
    case unknown
    case directGlobalAsyncFunctionDeclaration
}

@MainActor
public struct CallArguments {
    @MainActor
    public struct Argument {
        public let label: String?
        public let value: RuntimeValue
        public let isTrailing: Bool
        let sourceProvenance: CallArgumentSourceProvenance

        public init(label: String?, value: RuntimeValue, isTrailing: Bool = false) {
            self.label = label
            self.value = value
            self.isTrailing = isTrailing
            sourceProvenance = .unknown
        }

        init(
            label: String?,
            value: RuntimeValue,
            isTrailing: Bool = false,
            sourceProvenance: CallArgumentSourceProvenance
        ) {
            self.label = label
            self.value = value
            self.isTrailing = isTrailing
            self.sourceProvenance = sourceProvenance
        }
    }

    public var arguments: [Argument]
    /// Stable syntax position of the source call that produced these
    /// arguments. Host adapters use it only for semantics whose identity is
    /// owned by the call site (for example SwiftUI lifecycle modifiers).
    public let sourceSiteID: UInt64?

    public init(
        arguments: [Argument] = [], sourceSiteID: UInt64? = nil
    ) {
        self.arguments = arguments
        self.sourceSiteID = sourceSiteID
    }

    public var isEmpty: Bool { arguments.isEmpty }

    public func labeled(_ label: String) -> RuntimeValue? {
        arguments.first { $0.label == label }?.value
    }

    /// The n-th unlabeled, non-trailing argument (what a positional parameter binds).
    public func positional(_ index: Int) -> RuntimeValue? {
        guard index >= 0 else { return nil }
        var current = 0
        for argument in arguments where argument.label == nil && !argument.isTrailing {
            if current == index { return argument.value }
            current += 1
        }
        return nil
    }

    public func closure(labeled label: String) -> ClosureValue? {
        labeled(label)?.closureValue
    }

    /// First unlabeled closure without allocating an intermediate array.
    public var firstUnlabeledClosure: ClosureValue? {
        for argument in arguments where argument.label == nil {
            if let closure = argument.value.closureValue { return closure }
        }
        return nil
    }

    /// Last unlabeled closure without allocating an intermediate array.
    public var lastUnlabeledClosure: ClosureValue? {
        for argument in arguments.reversed() where argument.label == nil {
            if let closure = argument.value.closureValue { return closure }
        }
        return nil
    }

    /// Unlabeled closures in order (explicit unlabeled args and the first trailing closure).
    public var unlabeledClosures: [ClosureValue] {
        var closures: [ClosureValue] = []
        for argument in arguments where argument.label == nil {
            if let closure = argument.value.closureValue { closures.append(closure) }
        }
        return closures
    }
}

/// A gateway for `.modifier(...)` calls on host view values.
@MainActor
public struct HostModifier {
    public let name: String
    public let apply: @MainActor (RuntimeValue, CallArguments, EvalContext) throws -> RuntimeValue

    public init(name: String, apply: @escaping @MainActor (RuntimeValue, CallArguments, EvalContext) throws -> RuntimeValue) {
        self.name = name
        self.apply = apply
    }
}

/// What gateways can ask of the interpreter mid-call: run an interpreted
/// closure (Button actions, ForEach content) or evaluate one in ViewBuilder
/// mode (container content).
@MainActor
public protocol EvalContext: AnyObject {
    /// Logical executor currently running interpreted source. Cooperative
    /// builds may physically host every instruction on MainActor while still
    /// preserving source-level executor hops through this identity.
    var sourceExecutor: RuntimeExecutorKind { get }
    /// Structural identity contributed by enclosing collection builders.
    /// Interpreter-backed SwiftUI adapters use this to distinguish sibling
    /// rows created at one source call site.
    var currentViewIdentityPath: String { get }
    func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue
    /// Enter interpreted code from a synchronous external host callback such
    /// as a SwiftUI action. Interpreter-backed contexts override this entry to
    /// give source tasks a canonical concurrency-runtime session while keeping
    /// the callback itself synchronous.
    func callHostCallback(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue
    /// Suspension-aware callback for async gateways that need to invoke an
    /// interpreted completion/body without collapsing it back to sync.
    func callClosureAsync(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue
    /// Enter an async closure whose lifetime is owned by SwiftUI. The
    /// interpreter-backed implementation creates a fresh `.swiftUITask`
    /// session and maps cancellation of the native view task into the source
    /// runtime instead of reusing the render task that built the view.
    func callSwiftUITask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue
    /// Run one validated asynchronous host implementation while the bound
    /// source task is represented as waiting on a runtime-owned operation.
    /// Non-interpreter embedders inherit the transparent default below.
    func withHostOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T
    /// Execute one statically compiled, executor-neutral host operation on the
    /// opt-in bounded worker runtime. `nil` means that this context cannot
    /// safely offload the operation; the gateway must use its ordinary
    /// confined implementation instead. The builder is deliberately lazy:
    /// actor-confined and cooperative fallbacks must not copy arguments,
    /// execute gateway code, or otherwise observe a worker-only path. A
    /// builder may itself return `nil` after observing the arguments — an
    /// argument-sensitive decline back to the confined implementation.
    func runHostWorkerOperation(
        _ makeOperation: () throws -> HostWorkerOperation?
    ) async throws -> RuntimeValue?
    /// Create an interpreted Task. Async interpreter sessions schedule it on
    /// a real Swift task; synchronous compatibility sessions execute it
    /// deterministically before returning.
    func spawnBackgroundTask(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue
    /// Priority-aware task creation. Existing embedders inherit the default
    /// implementation below; the interpreter records this in its task runtime.
    func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue
    /// Name-aware creation used by the generated Swift concurrency surface.
    /// Names belong to the new task and are not inherited from its creator.
    func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue
    /// Create a source `Task.detached`. The interpreter overrides this to
    /// remove parent/task-local inheritance; older embedders retain a
    /// source-compatible fallback to ordinary background work.
    func spawnDetachedTask(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue
    func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue
    func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue
    /// Canonical source task creation where context inheritance, operation
    /// executor, and launch timing remain orthogonal. Generated immediate APIs
    /// use this entry; ordinary compatibility constructors keep older overloads.
    func spawnUnstructuredTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        contextInheritance: RuntimeTaskContextInheritance,
        startPolicy: RuntimeTaskStartPolicy,
        operationExecutor: RuntimeExecutorKind,
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue
    /// Read and scope a runtime task-local value while preserving the source
    /// task identity across synchronous and asynchronous host callbacks.
    func taskLocalValue(for key: RuntimeTaskLocalKey) -> RuntimeValue?
    func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) throws -> RuntimeValue
    func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) async throws -> RuntimeValue
    /// Let a core builtin with a colliding Swift name defer non-builtin call
    /// shapes to the injected host type (`Task(context:)` for a generated
    /// Core Data entity versus concurrency `Task {}`).
    func invokeHostConstructor(named name: String, arguments: CallArguments) throws -> RuntimeValue?
    /// Task-body semantics: runs on a bounded slice, parks (returns quietly)
    /// on slice exhaustion, and never charges the caller's step budget.
    func callBackgroundClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue
    func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue]
    /// Bracket one element of a host-materialized, therefore known-finite,
    /// iteration. Interpreter contexts give the element an independent
    /// bounded budget; other embedders simply execute it. The element body
    /// itself remains bounded, so this cannot hide an infinite callback.
    func withKnownFiniteHostIteration<T>(
        _ operation: () throws -> T
    ) throws -> T
    /// Resolve a static member supplied by an interpreted extension while a
    /// host coercion is running. Interpreter-backed contexts bind this lookup
    /// to the current program entry; other embedders have no source extension
    /// state and use the nil default below.
    func sourceStaticMember(
        named member: String, ofType typeName: String
    ) throws -> RuntimeValue?
    /// Compare values with source-declared and synthesized equality when the
    /// context owns interpreted declarations. Native collection storage uses
    /// this witness for Set elements and Dictionary keys.
    func collectionStorageValuesAreEqual(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue
    ) throws -> Bool
    /// Runtime type services for parsed host declarations. Embedders get a
    /// complete primitive/container implementation by default; Interpreter
    /// augments it with source symbols and registry-owned opaque types.
    func hostTypeName(of value: RuntimeValue) -> String
    func hostValue(_ value: RuntimeValue, matchesType typeName: String) -> Bool
    func hostValue(_ value: RuntimeValue, conformsTo protocolName: String) -> Bool
}

extension EvalContext {
    public var sourceExecutor: RuntimeExecutorKind { .mainActor }
    public var currentViewIdentityPath: String { "" }

    /// Compatibility fallback for non-interpreter embedders. The interpreter
    /// supplies the task-aware implementation; legacy contexts preserve their
    /// established synchronous callback behavior.
    public func callHostCallback(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try callClosure(closure, arguments: arguments)
    }

    /// Source-compatible fallback for embedders that only implement the
    /// original synchronous callback surface. Interpreter supplies the real
    /// suspension-aware implementation.
    public func callClosureAsync(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        try callClosure(closure, arguments: arguments)
    }

    /// Compatibility fallback for non-interpreter embedders. SwiftUIBridge's
    /// interpreter context supplies the lifecycle-aware runtime entry.
    public func callSwiftUITask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        try await callClosureAsync(closure, arguments: arguments)
    }

    public func withHostOperation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await operation()
    }

    public func runHostWorkerOperation(
        _ makeOperation: () throws -> HostWorkerOperation?
    ) async throws -> RuntimeValue? {
        nil
    }

    public func withKnownFiniteHostIteration<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try operation()
    }

    public func sourceStaticMember(
        named member: String, ofType typeName: String
    ) throws -> RuntimeValue? {
        nil
    }

    public func collectionStorageValuesAreEqual(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue
    ) throws -> Bool {
        try Builtins.areEqual(lhs, rhs)
    }

    public func spawnDetachedTask(
        _ closure: ClosureValue, arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        try spawnBackgroundTask(closure, arguments: arguments)
    }

    public func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try spawnBackgroundTask(closure, arguments: arguments)
    }

    public func spawnBackgroundTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        throw RuntimeError(message:
            "Task creation requires a task-aware evaluation context")
    }

    public func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        try spawnDetachedTask(closure, arguments: arguments)
    }

    public func spawnDetachedTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        throw RuntimeError(message:
            "Task.detached creation requires a task-aware "
                + "evaluation context")
    }

    public func spawnUnstructuredTask(
        _ closure: ClosureValue,
        arguments: [RuntimeValue],
        contextInheritance: RuntimeTaskContextInheritance,
        startPolicy: RuntimeTaskStartPolicy,
        operationExecutor: RuntimeExecutorKind,
        name: String?,
        priority: RuntimeTaskPriority?
    ) throws -> RuntimeValue {
        guard startPolicy == .enqueued else {
            throw RuntimeError(message:
                "immediate task creation requires a task-aware "
                    + "evaluation context")
        }
        switch contextInheritance {
        case .inherited:
            return try spawnBackgroundTask(
                closure, arguments: arguments, name: name,
                priority: priority)
        case .detached:
            return try spawnDetachedTask(
                closure, arguments: arguments, name: name,
                priority: priority)
        }
    }

    public func taskLocalValue(for key: RuntimeTaskLocalKey) -> RuntimeValue? {
        nil
    }

    public func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) throws -> RuntimeValue {
        throw RuntimeError(message:
            "runtime task-local bindings require a task-aware evaluation context")
    }

    public func withTaskLocalValue(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: ClosureValue,
        arguments: [RuntimeValue]
    ) async throws -> RuntimeValue {
        throw RuntimeError(message:
            "runtime task-local bindings require a task-aware evaluation context")
    }

    public func hostTypeName(of value: RuntimeValue) -> String {
        HostRuntimeTypeSystem.typeName(of: value)
    }

    public func hostValue(
        _ value: RuntimeValue, matchesType typeName: String
    ) -> Bool {
        HostRuntimeTypeSystem.matches(value, type: typeName)
    }

    public func hostValue(
        _ value: RuntimeValue, conformsTo protocolName: String
    ) -> Bool {
        HostRuntimeTypeSystem.conforms(value, to: protocolName)
    }
}

/// Implemented by the SwiftUI bridge (and by the trace registry in tests).
/// The interpreter core never imports SwiftUI; view values flow through it
/// opaquely and all rendering decisions happen behind this protocol.
@MainActor
public protocol HostRegistry: AnyObject {
    /// Generated declarations compiled and imported by native semantic
    /// preflight. Runtime implementations remain in this registry; the module
    /// carries only their Swift-facing call contracts.
    var compilerPreflightHostModule: CompilerPreflightHostModule? { get }
    /// Typed top-level APIs implemented by the interpreter rather than an SDK
    /// module. Compiler preflight emits declarations from these exact runtime
    /// contracts and appends them to `compilerPreflightHostModule` (or creates
    /// a synthetic module when the registry has no SDK surface).
    ///
    /// SDK-backed functions must stay out of this list: their canonical
    /// declarations come from the generated module re-exports instead.
    var compilerPreflightSyntheticSignatures: [HostSignature] { get }
    /// Nominal declarations for receiver types that exist only behind this
    /// registry. Members remain sourced from typed host signatures; these
    /// declarations preserve enclosing-type attributes during native
    /// compiler preflight.
    var compilerPreflightSyntheticTypes: [CompilerPreflightHostType] { get }
    /// Real implementations for C functions worth answering truthfully
    /// (uname fills real host values). nil falls to the inert absorber.
    func cFunction(named name: String) -> HostFunction?
    /// SDK/module global values (`NSApp`) emitted from importer metadata.
    /// This precedes the unknown-uppercase-type absorber.
    func hostGlobal(named name: String) -> RuntimeValue?
    /// A metadata-recognized zero-argument C record constructor. Registries
    /// return a writable value only when their SDK surface proves the symbol
    /// is a record; unknown imported function results remain unresolved.
    func absorbedCValue(named name: String) -> RuntimeValue?
    func storeBlob(_ value: RuntimeValue, at path: String)
    func constructor(named name: String) -> HostFunction?
    /// Construct the generated native state backing a source subclass's
    /// imported direct superclass. Registries return a value only when
    /// interface metadata provides a matching zero-argument initializer;
    /// compatibility/opaque constructors must not participate.
    func hostSuperclassBacking(
        named typeName: String, in context: EvalContext
    ) throws -> RuntimeValue?
    func modifier(named name: String) -> HostModifier?
    func isViewValue(_ value: RuntimeValue) -> Bool
    /// Wrap a user-struct instance conforming to View into a renderable host value.
    func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue
    /// Group multiple builder-collected views into one (implicit TupleView stand-in).
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue
    /// Members on host-native values the core can't know (GeometryProxy.size,
    /// CGSize.width, …). Return nil for unknown names.
    func hostMember(_ name: String, on value: Any) -> RuntimeValue?
    /// Last-resort dynamic-member behavior for opaque imported values. This is
    /// deliberately separate from declared/bridged members: explicit member
    /// access may use it, while implicit-self lookup must continue searching
    /// lexical globals, imported functions, and constructors first.
    func fallbackHostMember(_ name: String, on value: Any) -> RuntimeValue?
    /// Parsed property contract, consulted before the legacy dynamic member
    /// hook. Registries can migrate one declaration at a time.
    func hostProperty(named name: String, on value: Any) -> HostProperty?
    /// `$published` projection: replay/live registries deliver the CURRENT
    /// value as a synchronous publisher (the doctrine fork); absorbed mode
    /// returns nil and the projection stays inert.
    func publishedProjection(current: RuntimeValue) -> RuntimeValue?
    /// Writable members on host-native values (formatter.dateFormat = "…").
    /// Return false when the member isn't settable.
    func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool
    /// Constructors for host object types (DateFormatter()) shared across
    /// real and trace registries. Return nil for unknown names.
    func hostObjectConstructor(named name: String) -> HostFunction?
    /// Host-typed operators the core can't know (`Text + Text`). Return nil
    /// to fall through to the numeric/string builtins.
    func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue?
    /// The host TYPE a native value stands for (AppStub → "UIApplication",
    /// a recorded node → its constructor name) so user extensions of host
    /// types dispatch on stubs. Nil when unknown.
    func hostTypeName(of value: Any) -> String?
    /// Resolves a dotted imported nested-type path only when interface-derived
    /// metadata proves that the path names a type. This keeps metatype chains
    /// distinct from opaque compiled-module member chains without guessing
    /// from capitalization.
    func importedNestedTypeName(for path: String) -> String?
    /// Registry-owned imported-type matching. This complements the core's
    /// primitive/source type system for generated SDK values and for opaque
    /// imported reference bags whose concrete class is unavailable on the
    /// interpreter's host platform.
    func hostValue(_ value: Any, matchesImportedType typeName: String) -> Bool
    /// Whether interface-derived imported nominal metadata proves that one
    /// named SDK type is the same as, inherits from, or conforms to another.
    /// This supplies type evidence for interpreter-owned source subclasses
    /// without requiring their native backing to exist on the current host.
    func importedType(
        named typeName: String, matchesImportedType expectedTypeName: String
    ) -> Bool
    /// Native ABI metadata for imported C/SDK value types. The interpreter
    /// derives source-struct layouts itself, but only the compiled host bridge
    /// can answer this without guessing for types it imports.
    func hostABILayout(ofTypeNamed name: String) -> RuntimeABILayout?
    /// PROTOCOL names a native value conforms to (a cancellation handle →
    /// ["Cancellable"]) so user protocol extensions (`extension Cancellable
    /// { func store(in:) }`) dispatch on host values. Empty when none.
    func hostProtocolCandidates(of value: Any) -> [String]
    /// Value-type member writes (`size.width = 300`): return the MUTATED
    /// COPY, or nil when the member isn't writable this way.
    func hostMutatedCopy(
        settingMember name: String, on value: Any, to newValue: RuntimeValue
    ) throws -> Any?
    /// CALL-site rescue for property/method name collisions on host values:
    /// `url.query` (property) shadowed `query(percentEncoded:)` — when the
    /// property's value turns out not to be callable, this asks for the
    /// METHOD by name, as native overload resolution would have picked.
    func hostMethod(_ name: String, on value: Any) -> RuntimeValue?
    /// Pure route metadata for source-synchronous host calls whose compiled
    /// implementation may use `HostWorkerOperation`. The evaluator consults
    /// this before evaluating an await-free static-member chain, so entering
    /// the async overlay never requires reading a source computed/lazy value
    /// or constructing the host receiver merely to discover capability.
    func hostMemberHasWorkerOperation(
        _ name: String,
        onStaticMember staticMember: String,
        ofType typeName: String
    ) -> Bool
}

extension HostRegistry {
    public var compilerPreflightHostModule: CompilerPreflightHostModule? { nil }
    public var compilerPreflightSyntheticSignatures: [HostSignature] { [] }
    public var compilerPreflightSyntheticTypes: [CompilerPreflightHostType] { [] }
    public func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue? { nil }
    public func hostGlobal(named name: String) -> RuntimeValue? { nil }
    public func hostSuperclassBacking(
        named typeName: String, in context: EvalContext
    ) throws -> RuntimeValue? { nil }
    public func hostTypeName(of value: Any) -> String? { nil }
    public func importedNestedTypeName(for path: String) -> String? { nil }
    public func hostValue(
        _ value: Any, matchesImportedType typeName: String
    ) -> Bool { false }
    public func importedType(
        named typeName: String, matchesImportedType expectedTypeName: String
    ) -> Bool { false }
    public func hostABILayout(ofTypeNamed name: String) -> RuntimeABILayout? { nil }
    public func hostProtocolCandidates(of value: Any) -> [String] { [] }
    public func hostMutatedCopy(
        settingMember name: String, on value: Any, to newValue: RuntimeValue
    ) throws -> Any? { nil }
    public func hostMember(_ name: String, on value: Any) -> RuntimeValue? { nil }
    public func fallbackHostMember(_ name: String, on value: Any) -> RuntimeValue? { nil }
    public func hostProperty(named name: String, on value: Any) -> HostProperty? { nil }
    public func hostMethod(_ name: String, on value: Any) -> RuntimeValue? { nil }
    public func hostMemberHasWorkerOperation(
        _ name: String,
        onStaticMember staticMember: String,
        ofType typeName: String
    ) -> Bool { false }
    public func publishedProjection(current: RuntimeValue) -> RuntimeValue? { nil }
    public func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool { false }
    public func hostObjectConstructor(named name: String) -> HostFunction? { nil }
}
