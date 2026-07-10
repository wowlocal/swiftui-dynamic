import SwiftSyntax

/// A computed property's accessors. `isBuilder` marks `@ViewBuilder`
/// members and `some View` return types — those evaluate in builder mode.
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
    public let isBuilder: Bool
    public let setter: Setter?

    public init(accessor: CodeBlockItemListSyntax, isBuilder: Bool, setter: Setter? = nil) {
        self.accessor = accessor
        self.isBuilder = isBuilder
        self.setter = setter
    }
}

/// A user-defined struct collected from source: stored properties (with their
/// initializer syntax and property-wrapper kind), computed properties, methods,
/// custom initializers, statics, and whether the inheritance clause mentions `View`.
public final class StructSymbol {
    public enum Wrapper: Equatable {
        case none
        case state
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
    /// The full inheritance clause — protocol-extension defaults dispatch
    /// through these names.
    public internal(set) var conformances: [String] = []
    /// `struct TagLayout: Layout` — containers whose custom layout math
    /// can't run; children render in a default flow (documented).
    public var conformsToLayout: Bool { conformances.contains("Layout") }
    /// Trailing-closure children of a Layout container, stashed at init.
    public static let layoutChildrenKey = "__layoutChildren"
    /// Declared with `class` — matters for observation; reference semantics
    /// are the default for ALL instances (the documented struct divergence).
    public internal(set) var isClass = false
    public internal(set) var conformsToObservableObject = false
    public internal(set) var observableViaMacro = false
    public struct StaticProperty {
        public let initializer: ExprSyntax
        public let typeAnnotation: TypeSyntax?
    }

    /// `subscript(index: Index) -> T? { get set }` — user subscripts.
    public struct SubscriptMember {
        public let parameters: [ClosureValue.Parameter]
        public let getter: CodeBlockItemListSyntax
        public let setter: ComputedProperty.Setter?
    }

    public internal(set) var subscripts: [SubscriptMember] = []
    public internal(set) var storedProperties: [StoredProperty] = []
    public internal(set) var computedProperties: [String: ComputedProperty] = [:]
    public internal(set) var methods: [String: [FunctionDeclSyntax]] = [:]
    public internal(set) var initializers: [InitializerDeclSyntax] = []
    public internal(set) var staticProperties: [String: StaticProperty] = [:]
    public internal(set) var staticMethods: [String: [FunctionDeclSyntax]] = [:]
    /// Types declared inside this type (`Outer.Kind`) — `.enumType`/`.type` values.
    public internal(set) var nestedTypes: [String: RuntimeValue] = [:]
    var staticCache: [String: RuntimeValue] = [:]
    /// `static var shared: ChatClient!` — declared without an initializer
    /// (extension statics): reads are nil until written (IUO fresh state).
    public var staticUninitialized: Set<String> = []

    public init(name: String, conformsToView: Bool) {
        self.name = name
        self.conformsToView = conformsToView
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
