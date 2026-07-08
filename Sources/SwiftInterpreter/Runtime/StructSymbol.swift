import SwiftSyntax

/// A user-defined struct collected from source: stored properties (with their
/// initializer syntax and `@State` flag), computed properties (accessor bodies),
/// methods, and whether the inheritance clause mentions `View`.
public final class StructSymbol {
    public struct StoredProperty {
        public let name: String
        public let isState: Bool
        public let initializer: ExprSyntax?
    }

    public let name: String
    public let conformsToView: Bool
    public internal(set) var storedProperties: [StoredProperty] = []
    public internal(set) var computedProperties: [String: CodeBlockItemListSyntax] = [:]
    public internal(set) var methods: [String: FunctionDeclSyntax] = [:]

    public init(name: String, conformsToView: Bool) {
        self.name = name
        self.conformsToView = conformsToView
    }

    public var statePropertyNames: [String] {
        storedProperties.filter(\.isState).map(\.name)
    }
}
