/// Interpreter-owned storage for a Swift `Optional`.
///
/// Keeping the wrapper in the value graph (instead of representing only
/// `.none` with a nil sentinel) preserves distinctions such as
/// `Int??.some(.none)` versus `Int??.none`.  `wrappedTypeName` also lets an
/// empty optional participate in generic overload matching without inventing
/// a payload merely to discover its type.
///
/// This node is reference-backed so the hot `RuntimeValue` enum can keep a
/// direct case while still representing recursively nested optionals.  The
/// node is immutable, so sharing it does not change value semantics.
@MainActor
public final class RuntimeOptionalValue {
    public let wrapped: RuntimeValue?
    public let wrappedTypeName: String?
    /// `T!` has Optional storage but implicitly unwraps in value-consuming
    /// contexts such as direct member access.
    public let isImplicitlyUnwrapped: Bool

    public init(
        wrapped: RuntimeValue?, wrappedTypeName: String? = nil,
        isImplicitlyUnwrapped: Bool = false
    ) {
        self.wrapped = wrapped
        self.wrappedTypeName = wrappedTypeName
        self.isImplicitlyUnwrapped = isImplicitlyUnwrapped
    }

    /// The source-shaped type name when the wrapped type is known.
    public var typeName: String? {
        wrappedTypeName.map { "\($0)\(isImplicitlyUnwrapped ? "!" : "?")" }
    }

    /// Peel exactly one outer Optional annotation. Both Swift spellings and
    /// implicitly-unwrapped optionals use the same runtime representation.
    public static func wrappedType(in rawTypeName: String) -> String? {
        let typeName = rawTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if typeName.hasSuffix("?") || typeName.hasSuffix("!") {
            return String(typeName.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard typeName.hasPrefix("Optional<"), typeName.hasSuffix(">") else {
            return nil
        }
        return String(typeName.dropFirst("Optional<".count).dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A non-lossy one-level view used by Optional language operations.
@MainActor
public enum RuntimeOptionalState {
    case notOptional
    case none(wrappedTypeName: String?)
    case some(RuntimeValue, wrappedTypeName: String?)
}

extension RuntimeValue {
    /// Build a typed `.none` for an Optional annotation, or retain the
    /// untyped nil sentinel when the annotation is not Optional.
    public static func none(forTypeAnnotation typeName: String) -> RuntimeValue {
        guard let wrapped = RuntimeOptionalValue.wrappedType(in: typeName) else {
            return .nilValue
        }
        return .none(
            wrappedTypeName: wrapped,
            isImplicitlyUnwrapped: typeName
                .trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("!"))
    }

    @inline(__always)
    public static func optional(
        _ wrapped: RuntimeValue?, wrappedTypeName: String? = nil,
        isImplicitlyUnwrapped: Bool = false
    ) -> RuntimeValue {
        .optional(RuntimeOptionalValue(
            wrapped: wrapped, wrappedTypeName: wrappedTypeName,
            isImplicitlyUnwrapped: isImplicitlyUnwrapped))
    }

    @inline(__always)
    public static func some(
        _ wrapped: RuntimeValue, wrappedTypeName: String? = nil,
        isImplicitlyUnwrapped: Bool = false
    ) -> RuntimeValue {
        .optional(
            wrapped, wrappedTypeName: wrappedTypeName,
            isImplicitlyUnwrapped: isImplicitlyUnwrapped)
    }

    @inline(__always)
    public static func none(
        wrappedTypeName: String? = nil,
        isImplicitlyUnwrapped: Bool = false
    ) -> RuntimeValue {
        .optional(
            nil, wrappedTypeName: wrappedTypeName,
            isImplicitlyUnwrapped: isImplicitlyUnwrapped)
    }

    public var optionalState: RuntimeOptionalState {
        switch self {
        case .optional(let optional):
            if let wrapped = optional.wrapped {
                return .some(wrapped, wrappedTypeName: optional.wrappedTypeName)
            }
            return .none(wrappedTypeName: optional.wrappedTypeName)
        case .nilValue:
            // The untyped nil literal remains a sentinel until context gives
            // it a wrapped type. Optional operations still treat it as none.
            return .none(wrappedTypeName: nil)
        default:
            return .notOptional
        }
    }

    /// Unwrap exactly one Optional layer. A legacy untyped nil has no value;
    /// a non-Optional passes through for compatibility with already accepted
    /// source that uses `??` on a concrete value.
    public var unwrappedOptionalOrSelf: RuntimeValue? {
        switch optionalState {
        case .some(let wrapped, _): return wrapped
        case .none: return nil
        case .notOptional: return self
        }
    }

    public var isOptional: Bool {
        if case .optional = self { return true }
        return false
    }

    /// Swift Optional injection, with SE-0230-style flattening when the value
    /// is already Optional (used by `try?`).
    public func liftedToOptional(wrappedTypeName: String? = nil) -> RuntimeValue {
        switch self {
        case .optional:
            return self
        case .nilValue:
            return .none(wrappedTypeName: wrappedTypeName)
        default:
            return .some(self, wrappedTypeName: wrappedTypeName)
        }
    }
}
