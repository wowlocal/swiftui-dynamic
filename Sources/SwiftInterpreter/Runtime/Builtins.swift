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
                // IEEE 754, exactly like real Swift: x/0 is ±inf, 0/0 is NaN.
                l / r
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
            if let l = lhs.intValue, let r = rhs.intValue, l <= r {
                return .native(l..<r)
            }
            if let l = lhs.doubleValue, let r = rhs.doubleValue, l <= r {
                return .native(l...r) // half-open doubles: iteration never materializes these
            }
            throw EvalMessage(text: "invalid range bounds")
        case "...":
            if let l = lhs.intValue, let r = rhs.intValue, l <= r {
                return .native(l..<(r + 1))
            }
            // `0.01...0.1` — fractional bounds (Slider ranges, random(in:)).
            if let l = lhs.doubleValue, let r = rhs.doubleValue, l <= r {
                return .native(l...r)
            }
            throw EvalMessage(text: "invalid range bounds")
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
            if let b = value.boolValue { return .native(!b) }
            // Hosted-object truths negate from their fresh-state false.
            if case .native(let any) = value,
               any is InertCallable || any is ImplicitMemberCall || any is ChainedImplicitCall {
                return .native(true)
            }
            throw EvalMessage(text: "'!' requires a Bool operand, got \(value.stringified)")
        default:
            throw EvalMessage(text: "unsupported prefix operator '\(op)'")
        }
    }

    /// The fresh-state numeric reading of an unknowable value: well-known
    /// numeric markers (.pi/.zero/.infinity…) map to their constants; hosted
    /// objects and unresolved chains read ZERO (the fresh canvas). Returns
    /// nil for real values — callers keep their concrete coercions.
    static func absorbedNumeric(_ value: RuntimeValue) -> Double? {
        if case .implicitMember(let name) = value {
            switch name {
            case "pi": return Double.pi
            case "zero": return 0
            case "infinity": return .infinity
            case "leastNonzeroMagnitude": return .leastNonzeroMagnitude
            case "greatestFiniteMagnitude": return .greatestFiniteMagnitude
            default: return nil
            }
        }
        if case .native(let any) = value,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            return 0.0
        }
        return nil
    }

    private static func arithmetic(
        _ op: String,
        _ lhs: RuntimeValue,
        _ rhs: RuntimeValue,
        int: (Int, Int) throws -> Int,
        double: (Double, Double) throws -> Double
    ) throws -> RuntimeValue {
        // Well-known numeric markers absorb in arithmetic: `x / .pi`.
        func numericMarker(_ value: RuntimeValue) -> Double? {
            guard case .implicitMember(let name) = value else { return nil }
            switch name {
            case "pi": return Double.pi
            case "zero": return 0
            case "infinity": return .infinity
            case "leastNonzeroMagnitude": return .leastNonzeroMagnitude
            case "greatestFiniteMagnitude": return .greatestFiniteMagnitude
            default: return nil
            }
        }
        func absorbed(_ value: RuntimeValue) -> RuntimeValue {
            if let numeric = numericMarker(value) { return .native(numeric) }
            // Hosted-object quantities and unresolved CHAINS read ZERO —
            // the fresh canvas (consistent with hosted truths reading false).
            if case .native(let any) = value,
               any is InertCallable || any is ChainedImplicitCall {
                return .native(0.0)
            }
            return value
        }
        let lhs = absorbed(lhs)
        let rhs = absorbed(rhs)
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
        // CG-shaped init markers (`.init(degrees:)`, `.init(width:height:)`)
        // do arithmetic on their labeled numeric arguments and rewrap, so
        // Angle * 0.1 and sizeA - sizeB stay typed markers for coercion.
        if let combined = try initMarkerArithmetic(op, lhs, rhs, double: double) {
            return combined
        }
        throw EvalMessage(text: "'\(op)' cannot combine \(lhs.stringified) and \(rhs.stringified)")
    }

    private static func initMarkerArithmetic(
        _ op: String,
        _ lhs: RuntimeValue,
        _ rhs: RuntimeValue,
        double: (Double, Double) throws -> Double
    ) throws -> RuntimeValue? {
        func initCall(_ value: RuntimeValue) -> ImplicitMemberCall? {
            if case .native(let any) = value, let call = any as? ImplicitMemberCall,
               call.name == "init", !call.arguments.arguments.isEmpty,
               call.arguments.arguments.allSatisfy({ $0.label != nil && $0.value.doubleValue != nil }) {
                return call
            }
            return nil
        }
        func rewrap(_ template: ImplicitMemberCall, _ values: [Double]) -> RuntimeValue {
            let rebuilt = zip(template.arguments.arguments, values).map {
                CallArguments.Argument(label: $0.label, value: .native($1))
            }
            return .native(ImplicitMemberCall(name: "init", arguments: CallArguments(arguments: rebuilt)))
        }
        if let l = initCall(lhs), let r = initCall(rhs),
           l.arguments.arguments.map(\.label) == r.arguments.arguments.map(\.label) {
            let combined = try zip(l.arguments.arguments, r.arguments.arguments).map {
                try double($0.value.doubleValue!, $1.value.doubleValue!)
            }
            return rewrap(l, combined)
        }
        if let l = initCall(lhs), let scalar = rhs.doubleValue {
            return rewrap(l, try l.arguments.arguments.map { try double($0.value.doubleValue!, scalar) })
        }
        if let r = initCall(rhs), let scalar = lhs.doubleValue {
            return rewrap(r, try r.arguments.arguments.map { try double(scalar, $0.value.doubleValue!) })
        }
        // `.zero + .init(degrees: 108)` — the bare zero marker is the init
        // marker's elementwise zero.
        if case .implicitMember("zero") = lhs, let r = initCall(rhs) {
            return rewrap(r, try r.arguments.arguments.map { try double(0, $0.value.doubleValue!) })
        }
        if case .implicitMember("zero") = rhs, let l = initCall(lhs) {
            return rewrap(l, try l.arguments.arguments.map { try double($0.value.doubleValue!, 0) })
        }
        return nil
    }

    static func areEqual(_ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Bool {
        if lhs.isNil || rhs.isNil { return lhs.isNil && rhs.isNil }
        // Chained markers compare by their final member name — honestly
        // false for `.current.orientation == .landscapeRight`.
        if case .native(let any) = lhs, let chain = any as? ChainedImplicitCall {
            if case .implicitMember(let name) = rhs { return chain.member == name }
            if case .native(let other) = rhs, let otherChain = other as? ChainedImplicitCall {
                return chain.member == otherChain.member
            }
        }
        if case .native(let any) = rhs, let chain = any as? ChainedImplicitCall,
           case .implicitMember(let name) = lhs {
            return chain.member == name
        }
        // Hosted objects compare by identity; against anything else, false.
        if case .native(let la) = lhs, la is InertCallable {
            if case .native(let ra) = rhs, ra is InertCallable {
                return (la as AnyObject) === (ra as AnyObject)
            }
            return false
        }
        if case .native(let ra) = rhs, ra is InertCallable { return false }
        // A bare marker against a CONCRETE non-marker value is unknowable —
        // false (`false == .cardHolderName`, `0 == .count`).
        if case .implicitMember = lhs,
           rhs.boolValue != nil || rhs.doubleValue != nil || rhs.stringValue != nil {
            return false
        }
        if case .implicitMember = rhs,
           lhs.boolValue != nil || lhs.doubleValue != nil || lhs.stringValue != nil {
            return false
        }
        // A marker CALL against a bare marker compares by name — honestly
        // false for `authorizationStatus(for: .video) == .authorized` (fresh
        // system state), true only for same-named markers.
        if case .native(let any) = lhs, let call = any as? ImplicitMemberCall,
           case .implicitMember(let name) = rhs {
            return call.name == name
        }
        if case .native(let any) = rhs, let call = any as? ImplicitMemberCall,
           case .implicitMember(let name) = lhs {
            return call.name == name
        }
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
            // Marker-call vs marker-call: name equality is the best truth
            // available (`.video == .video`); differing names are unequal.
            if let l = la as? ImplicitMemberCall, let r = ra as? ImplicitMemberCall {
                return l.name == r.name
            }
            if let l = la as? UUID, let r = ra as? UUID { return l == r }
            if let l = la as? AnyHashable, let r = ra as? AnyHashable { return l == r }
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
        // `.zero > 0.0` — well-known numeric markers absorb; hosted objects
        // read zero; remaining unresolved markers are unknowable and every
        // ordered comparison on them reads FALSE (fresh-state doctrine).
        func absorbed(_ value: RuntimeValue) -> RuntimeValue {
            if case .implicitMember(let name) = value {
                switch name {
                case "pi": return .native(Double.pi)
                case "zero": return .native(0.0)
                case "infinity": return .native(Double.infinity)
                default: break
                }
            }
            if case .native(let any) = value, any is InertCallable { return .native(0.0) }
            return value
        }
        let lhs = absorbed(lhs)
        let rhs = absorbed(rhs)
        func isUnknowable(_ value: RuntimeValue) -> Bool {
            if case .implicitMember = value { return true }
            if case .native(let any) = value {
                return any is ImplicitMemberCall || any is ChainedImplicitCall
            }
            return false
        }
        if isUnknowable(lhs) || isUnknowable(rhs) { return false }
        // Dates compare by time interval (`$0.creationDate < $1.creationDate`).
        if case .native(let la) = lhs, let l = la as? Date,
           case .native(let ra) = rhs, let r = ra as? Date {
            switch op {
            case "<": return l < r
            case "<=": return l <= r
            case ">": return l > r
            default: return l >= r
            }
        }
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
