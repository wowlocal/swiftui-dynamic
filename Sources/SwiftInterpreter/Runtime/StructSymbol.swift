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

        /// Function-typed or @ViewBuilder: what a trailing closure can fill.
        public var acceptsTrailingClosure: Bool {
            isBuilderClosure || (typeAnnotation?.trimmedDescription.contains("->") ?? false)
        }
    }

    public let name: String
    public let conformsToView: Bool
    /// UIViewRepresentable / NSViewRepresentable / …ControllerRepresentable —
    /// accepted in view position but rendered inert (documented divergence).
    public internal(set) var isRepresentable = false
    /// Declared with `class` — matters for observation; reference semantics
    /// are the default for ALL instances (the documented struct divergence).
    public internal(set) var isClass = false
    public internal(set) var conformsToObservableObject = false
    public internal(set) var observableViaMacro = false
    public struct StaticProperty {
        public let initializer: ExprSyntax
        public let typeAnnotation: TypeSyntax?
    }

    public internal(set) var storedProperties: [StoredProperty] = []
    public internal(set) var computedProperties: [String: ComputedProperty] = [:]
    public internal(set) var methods: [String: FunctionDeclSyntax] = [:]
    public internal(set) var initializers: [InitializerDeclSyntax] = []
    public internal(set) var staticProperties: [String: StaticProperty] = [:]
    public internal(set) var staticMethods: [String: FunctionDeclSyntax] = [:]
    /// Types declared inside this type (`Outer.Kind`) — `.enumType`/`.type` values.
    public internal(set) var nestedTypes: [String: RuntimeValue] = [:]
    var staticCache: [String: RuntimeValue] = [:]

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
}
