/// Binary and prefix operator implementations over `RuntimeValue`, with
/// Int/Double promotion. `&&`/`||` are short-circuited in the evaluator and
/// never reach this table. Errors are unlocated `EvalMessage`s; the evaluator
/// re-throws them with the operator node's source location.
enum Builtins {
    static func binary(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> RuntimeValue {
        switch op {
        case "+":
            if let l = lhs.stringValue, let r = rhs.stringValue { return .native(l + r) }
            if let l = lhs.arrayValue, let r = rhs.arrayValue { return .native(l + r) }
            return try arithmetic(op, lhs, rhs, int: { l, r in
                let (sum, overflow) = l.addingReportingOverflow(r)
                guard !overflow else { throw EvalMessage(text: "integer overflow") }
                return sum
            }, double: (+))
        case "-":
            return try arithmetic(op, lhs, rhs, int: { l, r in
                let (v, overflow) = l.subtractingReportingOverflow(r)
                guard !overflow else { throw EvalMessage(text: "integer overflow") }
                return v
            }, double: (-))
        case "*":
            return try arithmetic(op, lhs, rhs, int: { l, r in
                let (v, overflow) = l.multipliedReportingOverflow(by: r)
                guard !overflow else { throw EvalMessage(text: "integer overflow") }
                return v
            }, double: (*))
        case "/":
            return try arithmetic(op, lhs, rhs, int: { l, r in
                guard r != 0 else { throw EvalMessage(text: "division by zero") }
                return l / r
            }, double: { l, r in
                guard r != 0 else { throw EvalMessage(text: "division by zero") }
                return l / r
            })
        case "%":
            guard let l = lhs.intValue, let r = rhs.intValue else {
                throw EvalMessage(text: "'%' requires integer operands")
            }
            guard r != 0 else { throw EvalMessage(text: "division by zero") }
            return .native(l % r)
        case "==", "!=":
            let equal = try areEqual(lhs, rhs)
            return .native(op == "==" ? equal : !equal)
        case "<", "<=", ">", ">=":
            return .native(try compare(op, lhs, rhs))
        case "..<":
            guard let l = lhs.intValue, let r = rhs.intValue, l <= r else {
                throw EvalMessage(text: "invalid range bounds")
            }
            return .native(l..<r)
        case "...":
            guard let l = lhs.intValue, let r = rhs.intValue, l <= r else {
                throw EvalMessage(text: "invalid range bounds")
            }
            return .native(l..<(r + 1))
        default:
            throw EvalMessage(text: "unsupported operator '\(op)'")
        }
    }

    static func prefix(_ op: String, _ value: RuntimeValue) throws -> RuntimeValue {
        switch op {
        case "-":
            if let i = value.intValue { return .native(-i) }
            if let d = value.doubleValue { return .native(-d) }
            throw EvalMessage(text: "unary '-' requires a numeric operand")
        case "!":
            guard let b = value.boolValue else { throw EvalMessage(text: "'!' requires a Bool operand") }
            return .native(!b)
        default:
            throw EvalMessage(text: "unsupported prefix operator '\(op)'")
        }
    }

    private static func arithmetic(
        _ op: String,
        _ lhs: RuntimeValue,
        _ rhs: RuntimeValue,
        int: (Int, Int) throws -> Int,
        double: (Double, Double) throws -> Double
    ) throws -> RuntimeValue {
        if let l = lhs.intValue, let r = rhs.intValue { return .native(try int(l, r)) }
        if let l = lhs.doubleValue, let r = rhs.doubleValue { return .native(try double(l, r)) }
        throw EvalMessage(text: "'\(op)' cannot combine \(lhs.stringified) and \(rhs.stringified)")
    }

    private static func areEqual(_ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Bool {
        if case .nilValue = lhs { if case .nilValue = rhs { return true }; return false }
        if case .nilValue = rhs { return false }
        if let l = lhs.intValue, let r = rhs.intValue { return l == r }
        if let l = lhs.doubleValue, let r = rhs.doubleValue { return l == r }
        if let l = lhs.stringValue, let r = rhs.stringValue { return l == r }
        if let l = lhs.boolValue, let r = rhs.boolValue { return l == r }
        throw EvalMessage(text: "cannot compare \(lhs.stringified) and \(rhs.stringified)")
    }

    private static func compare(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Bool {
        if let l = lhs.stringValue, let r = rhs.stringValue {
            switch op {
            case "<": return l < r
            case "<=": return l <= r
            case ">": return l > r
            default: return l >= r
            }
        }
        guard let l = lhs.doubleValue, let r = rhs.doubleValue else {
            throw EvalMessage(text: "'\(op)' cannot compare \(lhs.stringified) and \(rhs.stringified)")
        }
        switch op {
        case "<": return l < r
        case "<=": return l <= r
        case ">": return l > r
        default: return l >= r
        }
    }
}
