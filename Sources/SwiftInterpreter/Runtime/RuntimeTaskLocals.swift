import SwiftSyntax

/// Stable identity for one runtime task-local declaration. Source-level
/// declarations use their syntax identity; host gateways use an explicit
/// namespace string. The two domains can never alias accidentally.
public struct RuntimeTaskLocalKey: Hashable, Sendable, CustomStringConvertible {
    private enum Identity: Hashable, Sendable {
        case host(String)
        case source(SyntaxIdentifier)
    }

    public let rawValue: String
    private let identity: Identity

    public init(rawValue: String) {
        self.rawValue = rawValue
        identity = .host(rawValue)
    }

    init(sourceDeclarationID: SyntaxIdentifier, debugName: String) {
        rawValue = "source:\(debugName)#\(sourceDeclarationID.indexInTree.toOpaque())"
        identity = .source(sourceDeclarationID)
    }

    public static func == (
        lhs: RuntimeTaskLocalKey, rhs: RuntimeTaskLocalKey
    ) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    public var description: String { rawValue }
}

/// Collected source declaration for `@TaskLocal static var`. The key is tied
/// to the binding node rather than the member spelling, so two declarations
/// named `value` remain independent. An absent initializer represents Swift's
/// implicit `nil` default for an optional declaration. The default has ordinary
/// static initialization semantics and is cached after the first successful
/// read.
final class RuntimeTaskLocalDeclaration {
    let key: RuntimeTaskLocalKey
    let initializer: ExprSyntax?
    let typeAnnotation: TypeSyntax?
    var cachedDefault: RuntimeValue?

    init(
        declarationID: SyntaxIdentifier,
        debugName: String,
        initializer: ExprSyntax?,
        typeAnnotation: TypeSyntax?
    ) {
        key = RuntimeTaskLocalKey(
            sourceDeclarationID: declarationID, debugName: debugName)
        self.initializer = initializer
        self.typeAnnotation = typeAnnotation
    }
}

/// Source-visible projected `$value`. Member dispatch exposes only the real
/// scoped-binding operation; it is not an absorbing property-wrapper stub.
final class RuntimeTaskLocalProjection: CustomStringConvertible {
    let key: RuntimeTaskLocalKey

    init(key: RuntimeTaskLocalKey) {
        self.key = key
    }

    var description: String { "TaskLocal<\(key)>" }
}

/// Mutable storage owned by exactly one interpreted task. Inheritance creates
/// a value-semantic snapshot rather than sharing this object with the child.
final class RuntimeTaskLocalStorage {
    private var values: [RuntimeTaskLocalKey: RuntimeValue]

    init(values: [RuntimeTaskLocalKey: RuntimeValue] = [:]) {
        self.values = values
    }

    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }

    func value(for key: RuntimeTaskLocalKey) -> RuntimeValue? {
        values[key]
    }

    func inheritedCopy() -> RuntimeTaskLocalStorage {
        RuntimeTaskLocalStorage(values: values.mapValues {
            $0.copiedForValueSemantics()
        })
    }

    func withValue<T>(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: () throws -> T
    ) rethrows -> T {
        let previous = values.updateValue(
            value.copiedForValueSemantics(), forKey: key)
        defer {
            if let previous {
                values[key] = previous
            } else {
                values.removeValue(forKey: key)
            }
        }
        return try operation()
    }

    func withValue<T>(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: () async throws -> T
    ) async rethrows -> T {
        let previous = values.updateValue(
            value.copiedForValueSemantics(), forKey: key)
        defer {
            if let previous {
                values[key] = previous
            } else {
                values.removeValue(forKey: key)
            }
        }
        return try await operation()
    }

    func removeAll() {
        values.removeAll(keepingCapacity: false)
    }
}
