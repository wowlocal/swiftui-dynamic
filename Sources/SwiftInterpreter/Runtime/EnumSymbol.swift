import SwiftSyntax

/// A user-defined enum: cases (with resolved raw values and associated-value
/// arity), methods, computed properties, and statics.
public final class EnumSymbol {
    public struct Case {
        public let name: String
        public let associatedLabels: [String?]
        /// Raw value resolved at collection time (literal or index/name default).
        public let rawValue: RuntimeValue
        /// Source annotations parallel to `associatedLabels`; retained so
        /// Optional and generic payloads are contextualized at construction.
        public let associatedTypeNames: [String]

        public var hasAssociatedValues: Bool { !associatedLabels.isEmpty }
    }

    public let name: String
    /// Inheritance-clause entries (raw type + protocols): protocol-extension
    /// members dispatch through these.
    public internal(set) var conformances: [String] = []
    /// Attached ATTRIBUTES (@Reducer, @ObservableState): macro-attributed
    /// enums generate nested types the merge can't see.
    public internal(set) var attributeNames: [String] = []
    public internal(set) var cases: [Case] = []
    public internal(set) var methods: [String: [FunctionDeclSyntax]] = [:]
    public internal(set) var computedProperties: [String: ComputedProperty] = [:]
    public internal(set) var staticProperties: [String: StructSymbol.StaticProperty] = [:]
    /// Source task-local declarations use the enum as a namespace but retain
    /// declaration identity independently of their textual member names.
    var taskLocalProperties: [String: RuntimeTaskLocalDeclaration] = [:]
    public internal(set) var staticMethods: [String: [FunctionDeclSyntax]] = [:]
    public internal(set) var staticComputedProperties: [String: ComputedProperty] = [:]
    public internal(set) var initializers: [InitializerDeclSyntax] = []
    /// Types declared inside the enum body (`TestCase.Cases`) — enums are
    /// namespaces as often as they are value types.
    public internal(set) var nestedTypes: [String: RuntimeValue] = [:]
    var staticCache: [String: RuntimeValue] = [:]
    /// Enum namespaces can own weak/unowned statics just like classes and
    /// structs. Those slots must not enter the strong static cache.
    var staticReferenceBoxes: [String: Box] = [:]
    public internal(set) var staticStoragePolicies:
        [String: StructSymbol.StaticStoragePolicy] = [:]
    public var staticUninitialized: Set<String> = []

    public init(name: String) {
        self.name = name
    }

    public func caseInfo(named name: String) -> Case? {
        cases.first { $0.name == name }
    }
}

/// A value of an interpreted enum: the case name plus any associated values.
public final class EnumCaseValue: CustomStringConvertible {
    public let symbol: EnumSymbol
    public let name: String
    public let associated: [RuntimeValue]

    public init(symbol: EnumSymbol, name: String, associated: [RuntimeValue] = []) {
        self.symbol = symbol
        self.name = name
        self.associated = associated
    }

    public var rawValue: RuntimeValue {
        symbol.caseInfo(named: name)?.rawValue ?? .nilValue
    }

    public var description: String {
        if associated.isEmpty { return "\(symbol.name).\(name)" }
        return "\(symbol.name).\(name)(" + associated.map(\.stringified).joined(separator: ", ") + ")"
    }
}
