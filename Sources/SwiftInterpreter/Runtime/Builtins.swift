import CoreGraphics
import Foundation

/// Binary and prefix operator implementations over `RuntimeValue`, with
/// Int/Double promotion. `&&`/`||`/`??` are short-circuited in the evaluator
/// and never reach this table. Errors are unlocated `EvalMessage`s; the
/// evaluator re-throws them with the operator node's source location.
public enum Builtins {
    /// Direct arithmetic/comparison on pure numeric operands — the hot path
    /// for loop counters and recursion, where the general path's marker
    /// adoption, registry consult, and absorption checks are all no-ops.
    /// Returns nil for anything that isn't a plain Int/Double pair (markers,
    /// Dates, strings, ranges) so the general path keeps its semantics.
    /// Int/Int overflow and division by zero throw exactly like `binary`.
    static func fastNumericBinary(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> RuntimeValue? {
        if let l = lhs.intValue, let r = rhs.intValue {
            switch op {
            case "+":
                let (v, overflow) = l.addingReportingOverflow(r)
                guard !overflow else { throw EvalMessage(text: "integer overflow") }
                return .native(v)
            case "-":
                let (v, overflow) = l.subtractingReportingOverflow(r)
                guard !overflow else { throw EvalMessage(text: "integer overflow") }
                return .native(v)
            case "*":
                let (v, overflow) = l.multipliedReportingOverflow(by: r)
                guard !overflow else { throw EvalMessage(text: "integer overflow") }
                return .native(v)
            case "/":
                guard r != 0 else { throw EvalMessage(text: "division by zero") }
                return .native(l / r)
            case "%":
                guard r != 0 else { throw EvalMessage(text: "division by zero") }
                return .native(l % r)
            case "==": return .native(l == r)
            case "!=": return .native(l != r)
            case "<": return .native(l < r)
            case "<=": return .native(l <= r)
            case ">": return .native(l > r)
            case ">=": return .native(l >= r)
            default: return nil
            }
        }
        guard let l = lhs.doubleValue, let r = rhs.doubleValue else { return nil }
        switch op {
        case "+": return .native(l + r)
        case "-": return .native(l - r)
        case "*": return .native(l * r)
        case "/": return .native(l / r) // IEEE 754: x/0 is ±inf, 0/0 is NaN
        case "==": return .native(l == r)
        case "!=": return .native(l != r)
        case "<": return .native(l < r)
        case "<=": return .native(l <= r)
        case ">": return .native(l > r)
        case ">=": return .native(l >= r)
        default: return nil // `%` on doubles errors in the general path
        }
    }

    static func binary(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> RuntimeValue {
        let usesDecimal: Bool = {
            if case .host(let any) = lhs, any is Decimal { return true }
            if case .host(let any) = rhs, any is Decimal { return true }
            return false
        }()
        if usesDecimal,
           let left = decimalValue(lhs), let right = decimalValue(rhs) {
            switch op {
            case "+": return .native(left + right)
            case "-": return .native(left - right)
            case "*": return .native(left * right)
            case "/": return .native(left / right)
            case "==": return .native(left == right)
            case "!=": return .native(left != right)
            case "<": return .native(left < right)
            case "<=": return .native(left <= right)
            case ">": return .native(left > right)
            case ">=": return .native(left >= right)
            default: break
            }
        }
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
        case "===", "!==":
            // Identity: interpreted instances are class-backed, host
            // objects compare by reference; everything else is not
            // identical.
            let same: Bool = {
                if case .instance(let l) = lhs, case .instance(let r) = rhs { return l === r }
                if case .host(let l) = lhs, case .host(let r) = rhs,
                   let lo = l as? AnyObject, let ro = r as? AnyObject {
                    return lo === ro
                }
                return false
            }()
            return .native(op == "===" ? same : !same)
        case "&+", "&-", "&*":
            // Overflow operators (protobuf hashing, bit mixers): true
            // wrapping arithmetic on our Int model.
            guard let l = absorbedNumeric(lhs).map({ Int($0) }) ?? lhs.intValue,
                  let r = absorbedNumeric(rhs).map({ Int($0) }) ?? rhs.intValue else {
                throw EvalMessage(text: "'\(op)' needs integers")
            }
            switch op {
            case "&+": return .native(l &+ r)
            case "&-": return .native(l &- r)
            default: return .native(l &* r)
            }
        case "&<<", "&>>":
            guard let l = lhs.intValue, let r = rhs.intValue else {
                throw EvalMessage(text: "'\(op)' needs integers")
            }
            return .native(op == "&<<" ? l &<< r : l &>> r)
        case "&", "|", "^", "<<", ">>":
            // Unknowable flags read ZERO (kFSEventStreamCreateFlag… C
            // constants from unmerged frameworks) — the arithmetic doctrine.
            guard let l = lhs.intValue ?? absorbedNumeric(lhs).map({ Int($0) }),
                  let r = rhs.intValue ?? absorbedNumeric(rhs).map({ Int($0) }) else {
                throw EvalMessage(text: "'\(op)' requires integer operands")
            }
            switch op {
            case "&": return .native(l & r)
            case "|": return .native(l | r)
            case "^": return .native(l ^ r)
            case "<<": return .native(l << r)
            default: return .native(l >> r)
            }
        case "..<":
            return try makeRange(lower: lhs, upper: rhs, includesUpperBound: false)
        case "...":
            return try makeRange(lower: lhs, upper: rhs, includesUpperBound: true)
        default:
            throw EvalMessage(text: "unsupported operator '\(op)'")
        }
    }

    private static func decimalValue(_ value: RuntimeValue) -> Decimal? {
        if case .host(let any) = value, let decimal = any as? Decimal { return decimal }
        if case .int(let integer) = value { return Decimal(integer) }
        if let double = value.doubleValue { return Decimal(double) }
        return nil
    }

    static func prefix(_ op: String, _ value: RuntimeValue) throws -> RuntimeValue {
        switch op {
        case "-":
            if let i = value.intValue { return .native(-i) }
            if let d = value.doubleValue { return .native(-d) }
            // Unknowables negate their fresh numeric reading (0 → 0).
            if let z = absorbedNumeric(value) { return .native(-z) }
            throw EvalMessage(text: "unary '-' requires a numeric operand")
        case "!":
            if let b = value.boolValue { return .native(!b) }
            // Hosted-object truths negate from their fresh-state reading.
            if let fresh = unknowableBool(value) { return .native(!fresh) }
            throw EvalMessage(text: "'!' requires a Bool operand, got \(value.stringified)")
        default:
            throw EvalMessage(text: "unsupported prefix operator '\(op)'")
        }
    }

    /// The fresh-state Bool reading of an unknowable value: an `isEmpty`
    /// chain reads TRUE — the same fresh collection iterates EMPTY in
    /// for-in and equals zero through `count == 0`, so all three readings
    /// agree (IceCubes' cache guard `!cachedItems.isEmpty` must fall to the
    /// network branch, as on a fresh install). Everything else reads FALSE
    /// (no biometrics, nothing running headlessly). Nil for real values.
    public static func unknowableBool(_ value: RuntimeValue) -> Bool? {
        if case .host(let any) = value {
            if let chain = any as? ChainedImplicitCall {
                return chain.member == "isEmpty"
            }
            if let call = any as? ImplicitMemberCall {
                return call.name == "isEmpty"
            }
            if any is InertCallable { return false }
            return nil
        }
        if case .hostFunction = value { return false }
        if case .implicitMember(let name) = value { return name == "isEmpty" }
        return nil
    }

    /// The fresh-state numeric reading of an unknowable value: well-known
    /// numeric markers (.pi/.zero/.infinity…) map to their constants; hosted
    /// objects and unresolved chains read ZERO (the fresh canvas). Returns
    /// nil for real values — callers keep their concrete coercions.
    public static func absorbedNumeric(_ value: RuntimeValue) -> Double? {
        let markerName: String? = {
            if case .implicitMember(let name) = value { return name }
            // TYPED markers (extended host types) read the same constants.
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               call.arguments.arguments.isEmpty {
                return call.name
            }
            return nil
        }()
        if let name = markerName {
            switch name {
            case "pi": return Double.pi
            case "zero": return 0
            case "infinity": return .infinity
            case "leastNonzeroMagnitude": return .leastNonzeroMagnitude
            case "greatestFiniteMagnitude": return .greatestFiniteMagnitude
            default: break // unresolved statics fall to the zero rule below
            }
        }
        if case .host(let any) = value,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            return 0.0
        }
        if case .hostFunction = value { return 0.0 } // bound stub member
        if case .implicitMember = value { return 0.0 } // unresolved static
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
            // Clock idioms: time ANCHORS read the fresh epoch (0), DURATION
            // statics read their seconds — `.now + .milliseconds(500)` is
            // 0.5, exactly like the DispatchTime `.now() + 0.5` rule.
            if case .host(let any) = value, let call = any as? ImplicitMemberCall {
                if call.name == "now", call.arguments.arguments.isEmpty { return 0 }
                if call.name == "random" {
                    let range = call.arguments.labeled("in") ?? call.arguments.positional(0)
                    if let bounds = range?.rangeValue?.halfOpenIntRange {
                        return Double(Int.random(in: bounds))
                    }
                    if let bounds = range?.rangeValue?.closedIntRange {
                        return Double(Int.random(in: bounds))
                    }
                    if let bounds = range?.rangeValue?.halfOpenDoubleRange {
                        return Double.random(in: bounds)
                    }
                    if let bounds = range?.rangeValue?.closedDoubleRange {
                        return Double.random(in: bounds)
                    }
                }
                if let quantity = (call.arguments.positional(0)?.doubleValue) {
                    switch call.name {
                    case "seconds": return quantity
                    case "milliseconds": return quantity / 1_000
                    case "microseconds": return quantity / 1_000_000
                    case "nanoseconds": return quantity / 1_000_000_000
                    case "minutes": return quantity * 60
                    case "hours": return quantity * 3_600
                    default: return nil
                    }
                }
                return nil
            }
            guard case .implicitMember(let name) = value else { return nil }
            switch name {
            case "pi": return Double.pi
            case "zero": return 0
            case "now": return 0
            case "infinity": return .infinity
            case "leastNonzeroMagnitude": return .leastNonzeroMagnitude
            case "greatestFiniteMagnitude": return .greatestFiniteMagnitude
            default: return nil
            }
        }
        func absorbed(_ value: RuntimeValue) -> RuntimeValue {
            if let numeric = numericMarker(value) { return .native(numeric) }
            // Hosted-object quantities, unresolved CHAINS, and bound host
            // member FUNCTIONS read ZERO — the fresh canvas (consistent
            // with hosted truths reading false).
            if case .host(let any) = value,
               any is InertCallable || any is ChainedImplicitCall {
                return .native(0.0)
            }
            if case .hostFunction = value { return .native(0.0) }
            // A bare `.member` no type context could resolve is an
            // unmerged-module static: fresh identity, zero.
            if case .implicitMember = value { return .native(0.0) }
            return value
        }
        // String concat with an unknowable operand: the unknowable reads
        // "" (the fresh string), same doctrine as numerics reading zero —
        // NSTemporaryDirectory() + "\(Date()).mov" yields the suffix.
        func isUnknowable(_ value: RuntimeValue) -> Bool {
            if case .host(let any) = value {
                return any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall
            }
            if case .hostFunction = value { return true }
            if case .implicitMember = value { return true }
            return false
        }
        if op == "+" {
            if let l = lhs.stringValue, isUnknowable(rhs) { return .native(l) }
            if let r = rhs.stringValue, isUnknowable(lhs) { return .native(r) }
            // Same doctrine for arrays: the unknowable side reads EMPTY —
            // `(target.plugins ?? []) + [.plugin(…)]` keeps the additions.
            if let l = lhs.arrayValue, isUnknowable(rhs) { return .native(l) }
            if let r = rhs.arrayValue, isUnknowable(lhs) { return .native(r) }
        }
        // BOTH sides unknowable — for ANY arithmetic op: the domain is
        // unknowable too (array concat vs signal math) — a CHAIN absorbs
        // correctly in every downstream context (numeric reads 0, for-in
        // reads empty, strings read ""). Runs BEFORE absorbed() zeroes
        // them — but TYPED marker pairs keep their own arithmetic:
        // init-markers combine elementwise, clock markers read seconds.
        func isInitMarker(_ value: RuntimeValue) -> Bool {
            (value.hostPayload as? ImplicitMemberCall)?.name == "init"
        }
        if isUnknowable(lhs), isUnknowable(rhs),
           numericMarker(lhs) == nil, numericMarker(rhs) == nil,
           !(isInitMarker(lhs) && isInitMarker(rhs)) {
            return .native(ChainedImplicitCall(
                base: lhs, member: op,
                arguments: CallArguments(arguments: [.init(label: nil, value: rhs)])))
        }
        let lhs = absorbed(lhs)
        let rhs = absorbed(rhs)
        if let l = lhs.intValue, let r = rhs.intValue { return .native(try int(l, r)) }
        if let l = lhs.doubleValue, let r = rhs.doubleValue { return .native(try double(l, r)) }
        // Real Foundation Date arithmetic: Date ± TimeInterval → Date,
        // Date − Date → TimeInterval.
        if op == "+" || op == "-" {
            if case .host(let la) = lhs, let anchor = la as? Date {
                if let offset = rhs.doubleValue {
                    return .native(anchor.addingTimeInterval(op == "+" ? offset : -offset))
                }
                if op == "-", case .host(let ra) = rhs, let other = ra as? Date {
                    return .native(anchor.timeIntervalSince(other))
                }
            }
            if op == "+", case .host(let ra) = rhs, let anchor = ra as? Date,
               let offset = lhs.doubleValue {
                return .native(anchor.addingTimeInterval(offset))
            }
        }
        // `.now() + 0.5` (DispatchTime deadlines) — the time anchor absorbs
        // into the numeric offset; delay-taking gateways (asyncAfter) read
        // the seconds directly.
        if op == "+" || op == "-",
           case .host(let any) = lhs, let call = any as? ImplicitMemberCall,
           call.name == "now", let offset = rhs.doubleValue {
            return .native(op == "+" ? offset : -offset)
        }
        // CG-shaped init markers (`.init(degrees:)`, `.init(width:height:)`)
        // do arithmetic on their labeled numeric arguments and rewrap, so
        // Angle * 0.1 and sizeA - sizeB stay typed markers for coercion.
        if let combined = try initMarkerArithmetic(op, lhs, rhs, double: double) {
            return combined
        }
        // BOTH-unknowable arithmetic (AudioKit's operation DSL:
        // `.phasor(f) * .randomNumberPulse(…)`): each side reads the fresh
        // zero — the general absorption, AFTER typed marker arithmetic
        // (init rewrap, clock offsets) had its chance.
        func isCallMarker(_ value: RuntimeValue) -> Bool {
            if let payload = value.hostPayload {
                return payload is ImplicitMemberCall || payload is ChainedImplicitCall
                    || payload is InertCallable
            }
            if case .implicitMember = value { return true }
            if case .hostFunction = value { return true }
            return false
        }

        if isCallMarker(lhs), let r = rhs.doubleValue {
            return .native(try double(0, r))
        }
        if isCallMarker(rhs), let l = lhs.doubleValue {
            return .native(try double(l, 0))
        }
        // A NIL beside a number can't compile natively (non-optional
        // operands) — it's an absorbed-environment artifact (a custom-
        // wrapper keypath subscript on a fresh store): fresh zero.
        if lhs.isNil, let r = rhs.doubleValue {
            return .native(try double(0, r))
        }
        if rhs.isNil, let l = lhs.doubleValue {
            return .native(try double(l, 0))
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
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
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

    static func comparisonResultName(_ result: ComparisonResult) -> String {
        switch result {
        case .orderedAscending: return "orderedAscending"
        case .orderedDescending: return "orderedDescending"
        case .orderedSame: return "orderedSame"
        }
    }

    static func areEqual(_ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Bool {
        // KeyPaths compare by their component chains (`kp == \\.zone`).
        if case .host(let l) = lhs, let lk = l as? KeyPathStub,
           case .host(let r) = rhs, let rk = r as? KeyPathStub {
            return lk.components == rk.components
        }
        // Real Foundation values compare for real (URL mock gates match
        // request URLs against recorded ones; thrown NSErrors compare with
        // their expectations).
        if case .host(let l) = lhs, let lu = l as? URL,
           case .host(let r) = rhs, let ru = r as? URL {
            return lu == ru
        }
        if case .host(let l) = lhs, let le = l as? NSError,
           case .host(let r) = rhs, let re = r as? NSError {
            return le.isEqual(re)
        }
        if lhs.isNil || rhs.isNil { return lhs.isNil && rhs.isNil }
        // Chained markers compare by their final member name — honestly
        // false for `.current.orientation == .landscapeRight`.
        if case .host(let any) = lhs, let chain = any as? ChainedImplicitCall {
            if case .implicitMember(let name) = rhs { return chain.member == name }
            if case .host(let other) = rhs, let otherChain = other as? ChainedImplicitCall {
                return chain.member == otherChain.member
            }
        }
        if case .host(let any) = rhs, let chain = any as? ChainedImplicitCall,
           case .implicitMember(let name) = lhs {
            return chain.member == name
        }
        // ComparisonResult is an @objc enum: hosted values print natively
        // (NSComparisonResult(rawValue:)) while corpus code compares with
        // `.orderedSame`-style markers — bridge by case name.
        if case .host(let any) = lhs, let result = any as? ComparisonResult,
           case .implicitMember(let name) = rhs {
            return comparisonResultName(result) == name
        }
        if case .host(let any) = rhs, let result = any as? ComparisonResult,
           case .implicitMember(let name) = lhs {
            return comparisonResultName(result) == name
        }
        // Hosted objects compare by identity; against anything else, false.
        if case .host(let la) = lhs, la is InertCallable {
            if case .host(let ra) = rhs, ra is InertCallable {
                return (la as AnyObject) === (ra as AnyObject)
            }
            return false
        }
        if case .host(let ra) = rhs, ra is InertCallable { return false }
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
        if case .host(let any) = lhs, let call = any as? ImplicitMemberCall,
           case .implicitMember(let name) = rhs {
            return call.name == name
        }
        if case .host(let any) = rhs, let call = any as? ImplicitMemberCall,
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
        if let l = lhs.rangeValue, let r = rhs.rangeValue { return try l.isEqual(to: r) }
        if let l = lhs.dictValue, let r = rhs.dictValue {
            // Dictionaries compare by entries, order-independent (native
            // Dictionary ==): every key exists on both sides, equal values.
            guard l.count == r.count else { return false }
            for (key, value) in zip(l.keys, l.values) {
                let other = try r.lookup(key)
                if other.isNil, !value.isNil { return false }
                if try !areEqual(value, other) { return false }
            }
            return true
        }
        if case .host(let la) = lhs, case .host(let ra) = rhs {
            // Marker-call vs marker-call: name equality is the best truth
            // available (`.video == .video`); differing names are unequal.
            if let l = la as? ImplicitMemberCall, let r = ra as? ImplicitMemberCall {
                return l.name == r.name
            }
            if let l = la as? HostTypeMarker, let r = ra as? HostTypeMarker {
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
        // Metatypes (`type(of: endpoint) == Oauth.self`) compare by symbol
        // identity, falling back to name (sibling-target re-declarations).
        case (.type(let l), .type(let r)):
            return l === r || l.name == r.name
        case (.enumType(let l), .enumType(let r)):
            return l === r || l.name == r.name
        case (.type, .enumType), (.enumType, .type):
            return false
        default:
            // Unknowable vs CONCRETE equality is false — a fresh chain
            // can't equal a specific value (marker-vs-concrete doctrine).
            func isUnknowable(_ value: RuntimeValue) -> Bool {
                if case .host(let any) = value {
                    return any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall
                }
                if case .implicitMember = value { return true }
                if case .hostFunction = value { return true }
                return false
            }
            if isUnknowable(lhs) != isUnknowable(rhs) {
                // Unknowable vs a concrete NUMBER compares through the
                // fresh zero (uname(&info) == 0 succeeds — status codes);
                // vs a concrete BOOL through the fresh Bool reading
                // (`cached.isEmpty == true` on a fresh store holds);
                // vs any other concrete it's simply unequal.
                let unknowable = isUnknowable(lhs) ? lhs : rhs
                let concrete = isUnknowable(lhs) ? rhs : lhs
                if let b = concrete.boolValue {
                    return b == (unknowableBool(unknowable) ?? false)
                }
                if let n = concrete.doubleValue { return n == 0 }
                return false
            }
            if isUnknowable(lhs), isUnknowable(rhs) {
                // Both unknowable: name equality is the best truth
                // ((function shapeKind) vs .none — different names differ).
                func markerName(_ value: RuntimeValue) -> String? {
                    if case .implicitMember(let name) = value { return name }
                    if case .hostFunction(let fn) = value { return fn.name }
                    if case .host(let any) = value {
                        if let call = any as? ImplicitMemberCall { return call.name }
                        if let chain = any as? ChainedImplicitCall { return chain.member }
                    }
                    return nil
                }
                if let l = markerName(lhs), let r = markerName(rhs) { return l == r }
                return false
            }
            throw EvalMessage(text: "cannot compare \(lhs.stringified) and \(rhs.stringified)")
        }
    }

    private static func compare(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Bool {
        // A NUMBER against a real Date compares through the epoch (an
        // absorbed store's fresh read is 0.0 = the epoch — "never fired").
        if case .host(let any) = rhs, let date = any as? Date, let n = lhs.doubleValue {
            return try compare(op, .native(n), .native(date.timeIntervalSince1970))
        }
        if case .host(let any) = lhs, let date = any as? Date, let n = rhs.doubleValue {
            return try compare(op, .native(date.timeIntervalSince1970), .native(n))
        }
        // Same-enum cases compare by DECLARATION ORDER — SE-0266's
        // synthesized Comparable (payload-less cases; OrderStatus's
        // placed < preparing < ready < completed).
        if case .enumCase(let l) = lhs, case .enumCase(let r) = rhs,
           l.symbol === r.symbol || l.symbol.name == r.symbol.name,
           l.associated.isEmpty, r.associated.isEmpty,
           let leftIndex = l.symbol.cases.firstIndex(where: { $0.name == l.name }),
           let rightIndex = r.symbol.cases.firstIndex(where: { $0.name == r.name }) {
            return try compare(op, .native(leftIndex), .native(rightIndex))
        }
        // Tuples compare LEXICOGRAPHICALLY — the version-triple idiom
        // (`(lhs.major, lhs.minor, lhs.patch) < (rhs.major, …)`).
        if let l = lhs.tupleValue, let r = rhs.tupleValue, l.values.count == r.values.count {
            for (a, b) in zip(l.values, r.values) {
                if (try? areEqual(a, b)) == true { continue }
                return try compare(op, a, b)
            }
            return op == "<=" || op == ">=" // fully equal
        }
        // Enum-case ORDERED comparisons: synthesized Comparable orders by
        // DECLARATION position (`stage > .welcome`), ignoring raw values;
        // an enum case against a NUMBER compares through its numeric raw.
        if case .enumCase(let l) = lhs, case .enumCase(let r) = rhs,
           l.symbol === r.symbol,
           let li = l.symbol.cases.firstIndex(where: { $0.name == l.name }),
           let ri = r.symbol.cases.firstIndex(where: { $0.name == r.name }) {
            return try compare(op, .native(li), .native(ri))
        }
        // `stage < .creation` where the bare `.member` never resolved:
        // the case's OWN symbol names it.
        if case .enumCase(let l) = lhs, case .implicitMember(let name) = rhs,
           let li = l.symbol.cases.firstIndex(where: { $0.name == l.name }),
           let ri = l.symbol.cases.firstIndex(where: { $0.name == name }) {
            return try compare(op, .native(li), .native(ri))
        }
        if case .enumCase(let r) = rhs, case .implicitMember(let name) = lhs,
           let ri = r.symbol.cases.firstIndex(where: { $0.name == r.name }),
           let li = r.symbol.cases.firstIndex(where: { $0.name == name }) {
            return try compare(op, .native(li), .native(ri))
        }
        if case .enumCase(let l) = lhs, let raw = l.rawValue.doubleValue, rhs.doubleValue != nil {
            return try compare(op, .native(raw), rhs)
        }
        if case .enumCase(let r) = rhs, let raw = r.rawValue.doubleValue, lhs.doubleValue != nil {
            return try compare(op, lhs, .native(raw))
        }
        // A case ordered against anything else it can't line up with reads
        // FALSE — the fresh-state doctrine for unknowable orderings.
        if case .enumCase = lhs { return false }
        if case .enumCase = rhs { return false }
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
            if case .host(let any) = value,
               any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                return .native(0.0)
            }
            if case .hostFunction = value { return .native(0.0) }
            // A bare `.member` no type context could resolve is an
            // unmerged-module static: fresh identity, zero.
            if case .implicitMember = value { return .native(0.0) }
            return value
        }
        let lhs = absorbed(lhs)
        let rhs = absorbed(rhs)
        func isUnknowable(_ value: RuntimeValue) -> Bool {
            if case .implicitMember = value { return true }
            if case .host(let any) = value {
                return any is ImplicitMemberCall || any is ChainedImplicitCall
            }
            return false
        }
        if isUnknowable(lhs) || isUnknowable(rhs) { return false }
        // Dates compare by time interval (`$0.creationDate < $1.creationDate`).
        if case .host(let la) = lhs, let l = la as? Date,
           case .host(let ra) = rhs, let r = ra as? Date {
            switch op {
            case "<": return l < r
            case "<=": return l <= r
            case ">": return l > r
            default: return l >= r
            }
        }
        // A NUMBER against a Date compares through the epoch — an absorbed
        // store's fresh read (0.0) is "never fired" against any real date.
        if case .host(let la) = lhs, let l = la as? Date, let r = rhs.doubleValue {
            return try compare(op, .native(l.timeIntervalSince1970), .native(r))
        }
        if case .host(let ra) = rhs, let r = ra as? Date, let l = lhs.doubleValue {
            return try compare(op, .native(l), .native(r.timeIntervalSince1970))
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

extension Builtins {
    /// A deep copy with NATIVE value semantics: struct instances copy
    /// recursively, classes stay references (native reference semantics),
    /// enum payloads/arrays/tuples/dictionaries copy element-wise, and
    /// everything else passes through. The CurrentValueSubject boundary
    /// uses this so stored state never aliases caller-held values —
    /// `let initial = AppState(); Store(initial)` then mutating the store
    /// leaves `initial` untouched, exactly like compiled Swift.
    public static func valueSemanticsCopy(_ value: RuntimeValue) -> RuntimeValue {
        switch value {
        case .array(let array):
            return .array(array.map(valueSemanticsCopy))
        case .tuple(let tuple):
            return .tuple(TupleValue(
                labels: tuple.labels, values: tuple.values.map(valueSemanticsCopy)))
        case .dictionary(let dictionary):
            return .dictionary(DictValue(
                keys: dictionary.keys.map(valueSemanticsCopy),
                values: dictionary.values.map(valueSemanticsCopy)))
        case .range(let range):
            return .range(RuntimeRangeValue(
                lowerBound: range.lowerBound.map(valueSemanticsCopy),
                upperBound: range.upperBound.map(valueSemanticsCopy),
                includesUpperBound: range.includesUpperBound))
        case .instance(let instance):
            guard !instance.symbol.isClass else { return value }
            let copy = Instance(symbol: instance.symbol)
            for (name, box) in instance.properties {
                copy.properties[name] = Box(valueSemanticsCopy(box.value))
            }
            for (name, box) in instance.stateBoxes {
                copy.stateBoxes[name] = Box(valueSemanticsCopy(box.value))
            }
            return .instance(copy)
        case .enumCase(let caseValue):
            guard !caseValue.associated.isEmpty else { return value }
            return .enumCase(EnumCaseValue(
                symbol: caseValue.symbol, name: caseValue.name,
                associated: caseValue.associated.map(valueSemanticsCopy)))
        case .host(let any):
            // Compatibility for embedders that still construct core values
            // with `.host` directly. New interpreter paths use typed cases.
            if let array = any as? [RuntimeValue] {
                return .array(array.map(valueSemanticsCopy))
            }
            if let tuple = any as? TupleValue {
                return .tuple(TupleValue(labels: tuple.labels, values: tuple.values.map(valueSemanticsCopy)))
            }
            if let dict = any as? DictValue {
                return .dictionary(DictValue(keys: dict.keys.map(valueSemanticsCopy),
                                             values: dict.values.map(valueSemanticsCopy)))
            }
            return value
        default:
            return value
        }
    }
}
