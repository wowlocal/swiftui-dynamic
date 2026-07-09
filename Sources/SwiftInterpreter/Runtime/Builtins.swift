import CoreGraphics
import Foundation

/// Binary and prefix operator implementations over `RuntimeValue`, with
/// Int/Double promotion. `&&`/`||`/`??` are short-circuited in the evaluator
/// and never reach this table. Errors are unlocated `EvalMessage`s; the
/// evaluator re-throws them with the operator node's source location.
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
        // `.now() + 0.5` (DispatchTime deadlines) — the time anchor absorbs
        // into the numeric offset; delay-taking gateways (asyncAfter) read
        // the seconds directly.
        if op == "+" || op == "-",
           case .native(let any) = lhs, let call = any as? ImplicitMemberCall,
           call.name == "now", let offset = rhs.doubleValue {
            return .native(op == "+" ? offset : -offset)
        }
        throw EvalMessage(text: "'\(op)' cannot combine \(lhs.stringified) and \(rhs.stringified)")
    }

    static func areEqual(_ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Bool {
        if lhs.isNil || rhs.isNil { return lhs.isNil && rhs.isNil }
        if let l = lhs.intValue, let r = rhs.intValue { return l == r }
        if let l = lhs.doubleValue, let r = rhs.doubleValue { return l == r }
        if let l = lhs.stringValue, let r = rhs.stringValue { return l == r }
        if let l = lhs.boolValue, let r = rhs.boolValue { return l == r }
        if let l = lhs.arrayValue, let r = rhs.arrayValue {
            guard l.count == r.count else { return false }
            for (a, b) in zip(l, r) where try !areEqual(a, b) { return false }
            return true
        }
        if let l = lhs.tupleValue, let r = rhs.tupleValue {
            guard l.values.count == r.values.count else { return false }
            for (a, b) in zip(l.values, r.values) where try !areEqual(a, b) { return false }
            return true
        }
        if let l = lhs.rangeValue, let r = rhs.rangeValue { return l == r }
        if case .native(let la) = lhs, case .native(let ra) = rhs {
            if let l = la as? UUID, let r = ra as? UUID { return l == r }
            if let l = la as? Date, let r = ra as? Date { return l == r }
            if let l = la as? CGSize, let r = ra as? CGSize { return l == r }
            if let l = la as? CGPoint, let r = ra as? CGPoint { return l == r }
            if let l = la as? CGRect, let r = ra as? CGRect { return l == r }
        }
        if case .instance(let l) = lhs, case .instance(let r) = rhs { return l === r }
        // Enum cases compare by name (+ associated values); a bare implicit
        // member matches an enum case of the same name — the dynamic stand-in
        // for `status == .active`.
        switch (lhs, rhs) {
        case (.enumCase(let l), .enumCase(let r)):
            guard l.symbol === r.symbol || l.symbol.name == r.symbol.name, l.name == r.name,
                  l.associated.count == r.associated.count else { return false }
            for (a, b) in zip(l.associated, r.associated) where try !areEqual(a, b) { return false }
            return true
        case (.enumCase(let c), .implicitMember(let m)), (.implicitMember(let m), .enumCase(let c)):
            return c.name == m && c.associated.isEmpty
        case (.implicitMember(let l), .implicitMember(let r)):
            return l == r
        default:
            throw EvalMessage(text: "cannot compare \(lhs.stringified) and \(rhs.stringified)")
        }
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
