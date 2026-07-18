/// A typed view over `RuntimeValue` used by evaluator code.
///
/// A stable typed view over runtime storage. Core values have dedicated
/// `RuntimeValue` cases; opaque framework values alone flow through `.host`.
/// Evaluators switch on this view when they do not need to distinguish the
/// physical storage case, while gateways retain the `hostPayload` adapter.
@MainActor
public enum RuntimePayload {
    case void
    case nilValue
    case integer(Int)
    case floatingPoint(Double)
    case boolean(Bool)
    case string(String)
    case array([RuntimeValue])
    case dictionary(DictValue)
    case tuple(TupleValue)
    case range(RuntimeRangeValue)
    case instance(Instance)
    case closure(ClosureValue)
    case hostFunction(HostFunction)
    case type(StructSymbol)
    case enumType(EnumSymbol)
    case enumCase(EnumCaseValue)
    case implicitMember(String)
    case host(Any)
    /// Appended so existing payload tags remain stable for incremental
    /// clients compiled before dedicated Set storage landed.
    case set(RuntimeSetValue)
    /// A source-level Optional wrapper, including nested wrappers and the
    /// declared wrapped type when known.
    case optional(RuntimeOptionalValue)
}

extension RuntimeValue {
    /// Classify the runtime value without exposing how Swift-shaped values
    /// happen to be stored today. Core evaluator features should prefer this
    /// over downcasting `host(Any)` directly.
    public var payload: RuntimePayload {
        switch self {
        case .void:
            return .void
        case .nilValue:
            return .nilValue
        case .int(let value):
            return .integer(value)
        case .double(let value):
            return .floatingPoint(value)
        case .bool(let value):
            return .boolean(value)
        case .string(let value):
            return .string(value)
        case .array(let value):
            return .array(value)
        case .set(let value):
            return .set(value)
        case .optional(let value):
            return .optional(value)
        case .dictionary(let value):
            return .dictionary(value)
        case .tuple(let value):
            return .tuple(value)
        case .range(let value):
            return .range(value)
        case .instance(let value):
            return .instance(value)
        case .closure(let value):
            return .closure(value)
        case .hostFunction(let value):
            return .hostFunction(value)
        case .type(let value):
            return .type(value)
        case .enumType(let value):
            return .enumType(value)
        case .enumCase(let value):
            return .enumCase(value)
        case .implicitMember(let value):
            return .implicitMember(value)
        case .host(let value):
            // Compatibility for embedders compiled against the original
            // `host(Any)` representation. New core values are normalized by
            // `RuntimeValue.native(_:)` before reaching this branch.
            if let string = value as? String { return .string(string) }
            if let array = value as? [RuntimeValue] { return .array(array) }
            if let set = value as? RuntimeSetValue { return .set(set) }
            if let dictionary = value as? DictValue { return .dictionary(dictionary) }
            if let tuple = value as? TupleValue { return .tuple(tuple) }
            if let range = RuntimeRangeValue.fromNative(value) { return .range(range) }
            return .host(value)
        }
    }
}
