import SwiftSyntax

/// A computed property's accessors. `isBuilder` marks `@ViewBuilder`
/// members and `some View` return types — those evaluate in builder mode.
@MainActor
public struct ComputedProperty {
    public struct Setter {
        public let body: CodeBlockItemListSyntax
        /// `newValue`, or the custom name from `set(custom)`.
        public let parameterName: String

        public init(body: CodeBlockItemListSyntax, parameterName: String) {
            self.body = body
            self.parameterName = parameterName
        }
    }

    public let accessor: CodeBlockItemListSyntax
    /// Effect specifiers belong to the getter, not to the property binding.
    /// Preserve them independently so the async evaluator can choose a
    /// suspension-aware accessor entry instead of eagerly executing the body.
    public let isAsync: Bool
    public let isThrowing: Bool
    public let isBuilder: Bool
    public let setter: Setter?
    /// Explicit `nonisolated` belongs to the accessor declaration. Actor
    /// receivers use this bit to distinguish a direct, caller-executor read
    /// from the default actor-isolated computed-property entry.
    public let isNonisolated: Bool
    /// The declared result type supplies contextual type information to
    /// implicit-member returns such as `var manager: Manager { .shared }`.
    public let typeAnnotation: TypeSyntax?
    /// The pattern binding identifies the declaration's nominal lexical
    /// owner through Interpreter.declLexicalOwners without retaining it.
    public let declarationID: SyntaxIdentifier?

    public init(
        accessor: CodeBlockItemListSyntax, isBuilder: Bool,
        setter: Setter? = nil, typeAnnotation: TypeSyntax? = nil,
        declarationID: SyntaxIdentifier? = nil,
        isNonisolated: Bool = false,
        isAsync: Bool = false,
        isThrowing: Bool = false
    ) {
        self.accessor = accessor
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.isBuilder = isBuilder
        self.setter = setter
        self.typeAnnotation = typeAnnotation
        self.declarationID = declarationID
        self.isNonisolated = isNonisolated
    }
}

/// A user-defined struct collected from source: stored properties (with their
/// initializer syntax and property-wrapper kind), computed properties, methods,
/// custom initializers, statics, and whether the inheritance clause mentions `View`.
@MainActor
public final class StructSymbol {
    public enum Wrapper: Equatable {
        case none
        case state
        /// @Query/@FetchRequest — reads the LIVE model store each render.
        case query
        case binding
        case published
        case stateObject
        case observedObject
        case environmentObject
        /// `@Environment(\.colorScheme)` — payload is the key path (dots kept).
        case environment(String)
    }

    public struct StoredProperty {
        public let name: String
        public let wrapper: Wrapper
        public let initializer: ExprSyntax?
        public let typeAnnotation: TypeSyntax?
        /// `@ViewBuilder var content: Content` — memberwise init takes a
        /// trailing closure and stores the BUILT view.
        public let isBuilderClosure: Bool
        /// Source attributes remain explicit even when the bridge does not
        /// recognize them as one of its modeled wrappers. Physical lowering
        /// must not equate an unknown macro/wrapper with plain storage.
        public let attributeNames: [String]
        /// Mutable actor storage is confined to an owned executor segment.
        /// Immutable actor `let` storage remains directly readable, matching
        /// the Swift 6 compiler rule established by the native probe.
        public let isMutable: Bool
        /// Includes `nonisolated(unsafe)`: the compiler, rather than the actor
        /// mailbox, owns the safety contract for explicitly nonisolated data.
        public let isNonisolated: Bool
        /// `weak`/`unowned` are policies of the property's storage edge. The
        /// payload remains an ordinary class RuntimeValue everywhere else.
        public var referenceOwnership: ReferenceOwnership = .strong
        /// `lazy var keychain = KeychainManager(service: keychainService)` —
        /// the initializer defers to first access with self bound.
        public var isLazy: Bool = false
        /// Property OBSERVERS: assignment through the write funnel runs
        /// them (initialization does not, matching compiled Swift).
        public var willSetBody: CodeBlockItemListSyntax?
        public var willSetParameter: String = "newValue"
        public var didSetBody: CodeBlockItemListSyntax?
        public var didSetParameter: String = "oldValue"

        /// Function-typed or @ViewBuilder: what a trailing closure can fill.
        public var acceptsTrailingClosure: Bool {
            isBuilderClosure || (typeAnnotation?.trimmedDescription.contains("->") ?? false)
        }

        public var requiresActorExecutor: Bool {
            isMutable && !isNonisolated
        }
    }

    public let name: String
    /// Direct `: View` at declaration; the collector's post-pass also sets
    /// it for TRANSITIVE protocol conformance (`ConnectedView: View`).
    public internal(set) var conformsToView: Bool

    /// Renderable duck-typing: View conformers, representables, and any
    /// protocol-with-body shape (ToolbarContent, Commands, custom Scene
    /// content) — if it has a `body`, the render pipeline can evaluate it.
    public var rendersLikeView: Bool {
        conformsToView || isRepresentable || computedProperties["body"] != nil
    }
    /// UIViewRepresentable / NSViewRepresentable / …ControllerRepresentable —
    /// accepted in view position but rendered inert (documented divergence).
    public internal(set) var isRepresentable = false
    /// `struct WaterWave: Shape` — the bridge wraps these in a real Shape
    /// whose `path(in:)` delegates to the interpreted method.
    public internal(set) var conformsToShape = false
    /// `static var shared: X { … }` — computed statics, evaluated per read.
    public var staticComputedProperties: [String: ComputedProperty] = [:]
    /// `class Recognizer: NSObject, …` — the (non-protocol) superclass name;
    /// host superclasses make `super.*` inert, interpreted ones dispatch.
    public internal(set) var superclassName: String?
    /// `<Content: View, Style>` → ["Content": "View", "Style": ""] — used
    /// so properties typed by a GENERIC PARAMETER never synthesize as a
    /// same-named concrete type from elsewhere in the merge.
    public internal(set) var genericParameters: [String: String] = [:]
    /// Declaration order — generic-application decode zips arguments here.
    public internal(set) var orderedGenericParameters: [String] = []
    /// The full inheritance clause — protocol-extension defaults dispatch
    /// through these names.
    public internal(set) var conformances: [String] = []
    /// `struct TagLayout: Layout` — containers whose custom layout math
    /// can't run; children render in a default flow (documented).
    public var conformsToLayout: Bool { conformances.contains("Layout") }
    /// Trailing-closure children of a Layout container, stashed at init.
    public static let layoutChildrenKey = "__layoutChildren"
    /// Declared with `class`: class values retain Instance identity, while
    /// struct storage envelopes copy at language boundaries and detach nested
    /// values lazily through composed lvalues.
    public internal(set) var isClass = false
    /// Declared with `actor`. Actors retain reference identity like classes
    /// and receive a distinct runtime actor identity. Isolated method entry
    /// uses its logical executor; storage confinement and mailboxes remain a
    /// later runtime slice.
    public internal(set) var isActor = false
    /// A source-defined `unownedExecutor` replaces Swift's default actor
    /// executor. The cooperative mailbox cannot stand in for that capability;
    /// isolated entry fails closed until custom serial executors are modeled.
    public internal(set) var requiresCustomExecutorDispatch = false
    /// Declared `deinit` body. Source-class `Instance` values use host ARC;
    /// their final release delegates back to the interpreter to run this body.
    /// Explicit lifecycle cleanup remains supported and is idempotent.
    public internal(set) var deinitBody: CodeBlockSyntax?
    /// Executor that owns a deinitializer the runtime can execute faithfully.
    /// `Instance` itself is MainActor-isolated, so MainActor teardown already
    /// has a real host-executor capability; source-actor and user-global-actor
    /// teardown stay rejected until their executor capabilities can be owned.
    public internal(set) var deinitializerExecutor: RuntimeExecutorKind?
    /// Constructing this nominal would create a lifetime whose final release
    /// requires executor-owned teardown. Collection stays legal so unrelated
    /// project types do not fail up front; the common instance seed rejects
    /// the first actual construction until that teardown can be scheduled.
    public internal(set) var executorOwnedDeinitializerError: RuntimeError?
    public internal(set) var conformsToObservableObject = false
    public internal(set) var observableViaMacro = false
    public struct StaticProperty {
        public let initializer: ExprSyntax
        public let typeAnnotation: TypeSyntax?
        public let referenceOwnership: ReferenceOwnership

        public init(
            initializer: ExprSyntax, typeAnnotation: TypeSyntax?,
            referenceOwnership: ReferenceOwnership = .strong
        ) {
            self.initializer = initializer
            self.typeAnnotation = typeAnnotation
            self.referenceOwnership = referenceOwnership
        }
    }

    public struct StaticStoragePolicy {
        public let typeName: String?
        public let referenceOwnership: ReferenceOwnership

        public init(
            typeName: String?, referenceOwnership: ReferenceOwnership
        ) {
            self.typeName = typeName
            self.referenceOwnership = referenceOwnership
        }
    }

    /// `subscript(index: Index) -> T? { get set }` — user subscripts.
    public struct SubscriptMember {
        public let parameters: [ClosureValue.Parameter]
        public let getter: CodeBlockItemListSyntax
        /// Getter effects select the suspension-aware accessor driver. They
        /// cannot be reconstructed from the body after declaration parsing.
        public let isAsync: Bool
        public let isThrowing: Bool
        public let setter: ComputedProperty.Setter?
        public let resultTypeName: String?
        /// Actor subscripts are isolated by default. An explicit
        /// `nonisolated` modifier keeps both accessors on the caller executor.
        public let isNonisolated: Bool
        /// The declaration identifies its nominal lexical owner without
        /// retaining the syntax tree through a separate closure object.
        public let declarationID: SyntaxIdentifier?

        public init(
            parameters: [ClosureValue.Parameter],
            getter: CodeBlockItemListSyntax,
            setter: ComputedProperty.Setter?,
            resultTypeName: String?,
            isNonisolated: Bool = false,
            declarationID: SyntaxIdentifier? = nil,
            isAsync: Bool = false,
            isThrowing: Bool = false
        ) {
            self.parameters = parameters
            self.getter = getter
            self.isAsync = isAsync
            self.isThrowing = isThrowing
            self.setter = setter
            self.resultTypeName = resultTypeName
            self.isNonisolated = isNonisolated
            self.declarationID = declarationID
        }
    }

    /// Custom-property-wrapper STATICS (`@UserDefault("key", defaultValue:
    /// false) static var flag: Bool`): the wrapper ATTRIBUTE, applied at
    /// read time through the wrapper type's wrappedValue.
    public internal(set) var staticWrapped: [String: AttributeSyntax] = [:]

    /// Attached ATTRIBUTES (@ModelActor, @Observable) — macro-attributed
    /// types get tolerant memberwise binding for generated inits.
    public internal(set) var attributeNames: [String] = []
    public internal(set) var subscripts: [SubscriptMember] = []
    public internal(set) var storedProperties: [StoredProperty] = []
    public internal(set) var computedProperties: [String: ComputedProperty] = [:]
    public internal(set) var methods: [String: [FunctionDeclSyntax]] = [:]
    public internal(set) var initializers: [InitializerDeclSyntax] = []
    public internal(set) var staticProperties: [String: StaticProperty] = [:]
    /// Real source `@TaskLocal static var` declarations. Their defaults are
    /// static, while bound values live only in each runtime task's storage.
    var taskLocalProperties: [String: RuntimeTaskLocalDeclaration] = [:]
    public internal(set) var staticMethods: [String: [FunctionDeclSyntax]] = [:]
    /// Types declared inside this type (`Outer.Kind`) — `.enumType`/`.type` values.
    public internal(set) var nestedTypes: [String: RuntimeValue] = [:]
    var staticCache: [String: RuntimeValue] = [:]
    /// Non-owning static slots cannot live in `staticCache`, whose values are
    /// strong. Their boxes zero or trap through the same path as instance and
    /// local storage.
    var staticReferenceBoxes: [String: Box] = [:]
    public internal(set) var staticStoragePolicies: [String: StaticStoragePolicy] = [:]
    /// `static var shared: ChatClient!` — declared without an initializer
    /// (extension statics): reads are nil until written (IUO fresh state).
    public var staticUninitialized: Set<String> = []

    public init(name: String, conformsToView: Bool) {
        self.name = name
        self.conformsToView = conformsToView
    }

    /// A newer compatibility program may extend the same host type without
    /// mutating the synthetic symbol retained by an older escaped closure.
    /// Syntax/value members are copied as one MainActor-confined snapshot;
    /// subsequent collection mutates only the returned overlay.
    func copyForExtensionOverlay() -> StructSymbol {
        let copy = StructSymbol(name: name, conformsToView: conformsToView)
        copy.isRepresentable = isRepresentable
        copy.conformsToShape = conformsToShape
        copy.staticComputedProperties = staticComputedProperties
        copy.superclassName = superclassName
        copy.genericParameters = genericParameters
        copy.orderedGenericParameters = orderedGenericParameters
        copy.conformances = conformances
        copy.isClass = isClass
        copy.isActor = isActor
        copy.requiresCustomExecutorDispatch = requiresCustomExecutorDispatch
        copy.deinitBody = deinitBody
        copy.deinitializerExecutor = deinitializerExecutor
        copy.executorOwnedDeinitializerError = executorOwnedDeinitializerError
        copy.conformsToObservableObject = conformsToObservableObject
        copy.observableViaMacro = observableViaMacro
        copy.staticWrapped = staticWrapped
        copy.attributeNames = attributeNames
        copy.subscripts = subscripts
        copy.storedProperties = storedProperties
        copy.computedProperties = computedProperties
        copy.methods = methods
        copy.initializers = initializers
        copy.staticProperties = staticProperties
        copy.taskLocalProperties = taskLocalProperties
        copy.staticMethods = staticMethods
        copy.nestedTypes = nestedTypes
        copy.staticCache = staticCache
        copy.staticReferenceBoxes = staticReferenceBoxes
        copy.staticStoragePolicies = staticStoragePolicies
        copy.staticUninitialized = staticUninitialized
        return copy
    }

    public var isObservable: Bool {
        conformsToObservableObject || observableViaMacro
    }

    public var statePropertyNames: [String] {
        storedProperties.filter { $0.wrapper == .state }.map(\.name)
    }

    /// Properties whose boxes the bridge persists across view recreation:
    /// @State values and @StateObject models (the model instance lives in the
    /// persisted box).
    public var persistentPropertyNames: [String] {
        storedProperties.filter { $0.wrapper == .state || $0.wrapper == .stateObject }.map(\.name)
    }

    /// Properties whose mutation fires the instance's change signal:
    /// @Published for ObservableObject conformers, every plain stored property
    /// for @Observable classes.
    public var notifyingPropertyNames: [String] {
        guard isObservable else { return [] }
        if observableViaMacro {
            return storedProperties.filter { $0.wrapper == .none }.map(\.name)
        }
        return storedProperties.filter { $0.wrapper == .published }.map(\.name)
    }

    public func storedProperty(named name: String) -> StoredProperty? {
        storedProperties.first { $0.name == name }
    }

    /// `_offset` refers to `offset`'s wrapper storage in custom inits
    /// (`self._offset = offset`); returns the canonical property name.
    public func canonicalPropertyName(_ name: String) -> String {
        guard name.hasPrefix("_") else { return name }
        let stripped = String(name.dropFirst())
        return storedProperty(named: stripped) != nil ? stripped : name
    }
}
