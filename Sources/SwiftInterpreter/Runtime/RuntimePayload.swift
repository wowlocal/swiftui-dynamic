/// A typed view over `RuntimeValue` used by evaluator code.
///
/// `RuntimeValue.host(Any)` predates the interpreter's collection and value
/// semantics. Replacing it in one flag day would churn every gateway, so this
/// view is the migration boundary: core evaluation switches on explicit
/// Swift-shaped payloads while host frameworks continue receiving `Any` via
/// `RuntimeValue.hostPayload`. As storage moves to dedicated enum cases, this
/// API can stay stable.
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
            if let string = value as? String { return .string(string) }
            if let array = value as? [RuntimeValue] { return .array(array) }
            if let dictionary = value as? DictValue { return .dictionary(dictionary) }
            if let tuple = value as? TupleValue { return .tuple(tuple) }
            if let range = RuntimeRangeValue.fromNative(value) { return .range(range) }
            return .host(value)
        }
    }
}
