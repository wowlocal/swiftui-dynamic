import SwiftSyntax

/// A computed property's accessor body. `isBuilder` marks `@ViewBuilder`
/// members and `some View` return types — those evaluate in builder mode.
public struct ComputedProperty {
    public let accessor: CodeBlockItemListSyntax
    public let isBuilder: Bool

    public init(accessor: CodeBlockItemListSyntax, isBuilder: Bool) {
        self.accessor = accessor
        self.isBuilder = isBuilder
    }
}

/// A user-defined struct collected from source: stored properties (with their
/// initializer syntax and property-wrapper kind), computed properties, methods,
/// custom initializers, statics, and whether the inheritance clause mentions `View`.
public final class StructSymbol {
    public enum Wrapper {
        case none
        case state
        case binding
    }

    public struct StoredProperty {
        public let name: String
        public let wrapper: Wrapper
        public let initializer: ExprSyntax?
        public let typeAnnotation: TypeSyntax?
    }

    public let name: String
    public let conformsToView: Bool
    public internal(set) var storedProperties: [StoredProperty] = []
    public internal(set) var computedProperties: [String: ComputedProperty] = [:]
    public internal(set) var methods: [String: FunctionDeclSyntax] = [:]
    public internal(set) var initializers: [InitializerDeclSyntax] = []
    public internal(set) var staticProperties: [String: ExprSyntax] = [:]
    public internal(set) var staticMethods: [String: FunctionDeclSyntax] = [:]
    var staticCache: [String: RuntimeValue] = [:]

    public init(name: String, conformsToView: Bool) {
        self.name = name
        self.conformsToView = conformsToView
    }

    public var statePropertyNames: [String] {
        storedProperties.filter { $0.wrapper == .state }.map(\.name)
    }

    public func storedProperty(named name: String) -> StoredProperty? {
        storedProperties.first { $0.name == name }
    }
}
