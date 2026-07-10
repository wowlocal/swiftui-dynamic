import Foundation

/// The lossless runtime representation of every Swift range expression the
/// interpreter supports. A missing bound represents a partial range; Swift's
/// range operators always include the lower bound, so only the upper edge
/// needs an inclusivity bit.
public struct RuntimeRangeValue: CustomStringConvertible {
    public let lowerBound: RuntimeValue?
    public let upperBound: RuntimeValue?
    public let includesUpperBound: Bool

    public init(
        lowerBound: RuntimeValue? = nil,
        upperBound: RuntimeValue? = nil,
        includesUpperBound: Bool = false
    ) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.includesUpperBound = includesUpperBound
    }

    public var isPartial: Bool { lowerBound == nil || upperBound == nil }

    public var description: String {
        switch (lowerBound, upperBound) {
        case let (lower?, upper?):
            return lower.stringified + (includesUpperBound ? "..." : "..<") + upper.stringified
        case let (lower?, nil):
            return lower.stringified + "..."
        case let (nil, upper?):
            return (includesUpperBound ? "..." : "..<") + upper.stringified
        case (nil, nil):
            return "..."
        }
    }

    /// Exact native projections. They intentionally preserve open/closed
    /// shape instead of silently changing one into the other.
    public var halfOpenIntRange: Range<Int>? {
        guard !includesUpperBound,
              let lower = lowerBound?.intValue,
              let upper = upperBound?.intValue else { return nil }
        return lower..<upper
    }

    public var closedIntRange: ClosedRange<Int>? {
        guard includesUpperBound,
              let lower = lowerBound?.intValue,
              let upper = upperBound?.intValue else { return nil }
        return lower...upper
    }

    public var halfOpenDoubleRange: Range<Double>? {
        guard !includesUpperBound,
              let lower = lowerBound?.doubleValue,
              let upper = upperBound?.doubleValue else { return nil }
        return lower..<upper
    }

    public var closedDoubleRange: ClosedRange<Double>? {
        guard includesUpperBound,
              let lower = lowerBound?.doubleValue,
              let upper = upperBound?.doubleValue else { return nil }
        return lower...upper
    }

    /// Integer ranges are the only supported range Collections. Fractional,
    /// date and string ranges remain RangeExpressions, matching native Swift.
    public func integerValues() -> [RuntimeValue]? {
        if let range = halfOpenIntRange {
            return range.map { .native($0) }
        }
        if let range = closedIntRange {
            return range.map { .native($0) }
        }
        return nil
    }

    /// RangeExpression containment with numeric promotion. Integer literals
    /// in a Double switch pattern therefore adopt the subject's numeric
    /// domain without truncating either bound.
    public func contains(_ candidate: RuntimeValue) throws -> Bool {
        if Self.isUnknowable(candidate) { return false }
        if let lowerBound {
            let order = try Self.compare(candidate, lowerBound)
            if order < 0 { return false }
        }
        if let upperBound {
            let order = try Self.compare(candidate, upperBound)
            return includesUpperBound ? order <= 0 : order < 0
        }
        return true
    }

    public func isEmpty() throws -> Bool {
        guard let lowerBound, let upperBound else { return false }
        if includesUpperBound { return false }
        return try Self.compare(lowerBound, upperBound) == 0
    }

    func isEqual(to other: RuntimeRangeValue) throws -> Bool {
        guard includesUpperBound == other.includesUpperBound else { return false }
        return try Self.optionalEqual(lowerBound, other.lowerBound)
            && Self.optionalEqual(upperBound, other.upperBound)
    }

    func coercingBounds(to typeName: String) throws -> RuntimeRangeValue {
        let target = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let coerce: (RuntimeValue?) throws -> RuntimeValue? = { value in
            guard let value else { return nil }
            if Interpreter.doubleFamilyTypeNames.contains(target) {
                guard let number = value.doubleValue else {
                    throw EvalMessage(text: "range bound \(value.stringified) is not a \(target)")
                }
                return .native(number)
            }
            if target == "Int" {
                guard let integer = value.intValue else {
                    throw EvalMessage(text: "range bound \(value.stringified) is not an Int")
                }
                return .native(integer)
            }
            if target == "String" {
                guard value.stringValue != nil else {
                    throw EvalMessage(text: "range bound \(value.stringified) is not a String")
                }
                return value
            }
            if target == "Date" {
                guard case .host(let any) = value, any is Date else {
                    throw EvalMessage(text: "range bound \(value.stringified) is not a Date")
                }
                return value
            }
            if target == "String.Index" {
                guard case .host(let any) = value, any is String.Index else {
                    throw EvalMessage(text: "range bound \(value.stringified) is not a String.Index")
                }
                return value
            }
            return value
        }
        return RuntimeRangeValue(
            lowerBound: try coerce(lowerBound),
            upperBound: try coerce(upperBound),
            includesUpperBound: includesUpperBound)
    }

    func matchesNominalShape(_ name: String) -> Bool {
        switch name {
        case "Range":
            return lowerBound != nil && upperBound != nil && !includesUpperBound
        case "ClosedRange":
            return lowerBound != nil && upperBound != nil && includesUpperBound
        case "PartialRangeFrom":
            return lowerBound != nil && upperBound == nil
        case "PartialRangeUpTo":
            return lowerBound == nil && upperBound != nil && !includesUpperBound
        case "PartialRangeThrough":
            return lowerBound == nil && upperBound != nil && includesUpperBound
        default:
            return false
        }
    }

    private static func optionalEqual(_ lhs: RuntimeValue?, _ rhs: RuntimeValue?) throws -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return try Builtins.areEqual(lhs, rhs)
        default: return false
        }
    }

    private static func compare(_ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Int {
        if let lhsInt = lhs.intValue, let rhsInt = rhs.intValue {
            return lhsInt < rhsInt ? -1 : (lhsInt > rhsInt ? 1 : 0)
        }
        if let lhsDouble = lhs.doubleValue, let rhsDouble = rhs.doubleValue {
            if lhsDouble.isNaN || rhsDouble.isNaN {
                throw EvalMessage(text: "range bounds and candidates cannot be NaN")
            }
            return lhsDouble < rhsDouble ? -1 : (lhsDouble > rhsDouble ? 1 : 0)
        }
        if let lhsString = lhs.stringValue, let rhsString = rhs.stringValue {
            return lhsString < rhsString ? -1 : (lhsString > rhsString ? 1 : 0)
        }
        if case .host(let lhsAny) = lhs, let lhsDate = lhsAny as? Date,
           case .host(let rhsAny) = rhs, let rhsDate = rhsAny as? Date {
            return lhsDate < rhsDate ? -1 : (lhsDate > rhsDate ? 1 : 0)
        }
        if case .host(let lhsAny) = lhs, let lhsIndex = lhsAny as? String.Index,
           case .host(let rhsAny) = rhs, let rhsIndex = rhsAny as? String.Index {
            return lhsIndex < rhsIndex ? -1 : (lhsIndex > rhsIndex ? 1 : 0)
        }
        throw EvalMessage(text: "cannot compare range value \(lhs.stringified) and \(rhs.stringified)")
    }

    private static func isUnknowable(_ value: RuntimeValue) -> Bool {
        if case .implicitMember = value { return true }
        if case .hostFunction = value { return true }
        if case .host(let any) = value {
            return any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall
        }
        return false
    }

    /// Adapts ranges returned by host APIs into the interpreter's one range
    /// representation. Interpreted range operators already construct this
    /// type directly; this closes the boundary for Foundation/SwiftUI hosts.
    static func fromNative(_ any: Any) -> RuntimeRangeValue? {
        if let range = any as? RuntimeRangeValue { return range }

        if let range = any as? Range<Int> { return full(range.lowerBound, range.upperBound, false) }
        if let range = any as? ClosedRange<Int> { return full(range.lowerBound, range.upperBound, true) }
        if let range = any as? Range<Double> { return full(range.lowerBound, range.upperBound, false) }
        if let range = any as? ClosedRange<Double> { return full(range.lowerBound, range.upperBound, true) }
        if let range = any as? Range<Date> { return full(range.lowerBound, range.upperBound, false) }
        if let range = any as? ClosedRange<Date> { return full(range.lowerBound, range.upperBound, true) }
        if let range = any as? Range<String> { return full(range.lowerBound, range.upperBound, false) }
        if let range = any as? ClosedRange<String> { return full(range.lowerBound, range.upperBound, true) }
        if let range = any as? Range<String.Index> { return full(range.lowerBound, range.upperBound, false) }
        if let range = any as? ClosedRange<String.Index> { return full(range.lowerBound, range.upperBound, true) }

        if let range = any as? PartialRangeFrom<Int> { return lower(range.lowerBound) }
        if let range = any as? PartialRangeUpTo<Int> { return upper(range.upperBound, false) }
        if let range = any as? PartialRangeThrough<Int> { return upper(range.upperBound, true) }
        if let range = any as? PartialRangeFrom<Double> { return lower(range.lowerBound) }
        if let range = any as? PartialRangeUpTo<Double> { return upper(range.upperBound, false) }
        if let range = any as? PartialRangeThrough<Double> { return upper(range.upperBound, true) }
        if let range = any as? PartialRangeFrom<Date> { return lower(range.lowerBound) }
        if let range = any as? PartialRangeUpTo<Date> { return upper(range.upperBound, false) }
        if let range = any as? PartialRangeThrough<Date> { return upper(range.upperBound, true) }
        if let range = any as? PartialRangeFrom<String> { return lower(range.lowerBound) }
        if let range = any as? PartialRangeUpTo<String> { return upper(range.upperBound, false) }
        if let range = any as? PartialRangeThrough<String> { return upper(range.upperBound, true) }
        if let range = any as? PartialRangeFrom<String.Index> { return lower(range.lowerBound) }
        if let range = any as? PartialRangeUpTo<String.Index> { return upper(range.upperBound, false) }
        if let range = any as? PartialRangeThrough<String.Index> { return upper(range.upperBound, true) }
        return nil
    }

    private static func value<T>(_ value: T) -> RuntimeValue {
        .native(value as Any)
    }

    private static func full<T>(_ lower: T, _ upper: T, _ inclusive: Bool) -> RuntimeRangeValue {
        RuntimeRangeValue(
            lowerBound: value(lower), upperBound: value(upper), includesUpperBound: inclusive)
    }

    private static func lower<T>(_ lower: T) -> RuntimeRangeValue {
        RuntimeRangeValue(lowerBound: value(lower))
    }

    private static func upper<T>(_ upper: T, _ inclusive: Bool) -> RuntimeRangeValue {
        RuntimeRangeValue(upperBound: value(upper), includesUpperBound: inclusive)
    }
}

extension Builtins {
    static func makeRange(
        lower rawLower: RuntimeValue,
        upper rawUpper: RuntimeValue,
        includesUpperBound: Bool
    ) throws -> RuntimeValue {
        var lower = rawLower
        var upper = rawUpper

        if let absorbed = absorbedRangeBound(lower, peer: upper) { lower = absorbed }
        if let absorbed = absorbedRangeBound(upper, peer: lower) { upper = absorbed }

        if let lowerInt = lower.intValue, let upperInt = upper.intValue {
            guard lowerInt <= upperInt else { throw EvalMessage(text: "invalid range bounds") }
            return .native(RuntimeRangeValue(
                lowerBound: .native(lowerInt),
                upperBound: .native(upperInt),
                includesUpperBound: includesUpperBound))
        }

        if let lowerDouble = lower.doubleValue, let upperDouble = upper.doubleValue {
            guard !lowerDouble.isNaN, !upperDouble.isNaN, lowerDouble <= upperDouble else {
                throw EvalMessage(text: "invalid range bounds")
            }
            return .native(RuntimeRangeValue(
                lowerBound: .native(lowerDouble),
                upperBound: .native(upperDouble),
                includesUpperBound: includesUpperBound))
        }

        if case .host(let lowerAny) = lower, let lowerDate = lowerAny as? Date,
           case .host(let upperAny) = upper, let upperDate = upperAny as? Date {
            guard lowerDate <= upperDate else { throw EvalMessage(text: "invalid range bounds") }
            return .native(RuntimeRangeValue(
                lowerBound: .native(lowerDate),
                upperBound: .native(upperDate),
                includesUpperBound: includesUpperBound))
        }

        if let lowerString = lower.stringValue, let upperString = upper.stringValue {
            guard lowerString <= upperString else { throw EvalMessage(text: "invalid range bounds") }
            return .native(RuntimeRangeValue(
                lowerBound: .native(lowerString),
                upperBound: .native(upperString),
                includesUpperBound: includesUpperBound))
        }

        if case .host(let lowerAny) = lower, let lowerIndex = lowerAny as? String.Index,
           case .host(let upperAny) = upper, let upperIndex = upperAny as? String.Index {
            guard lowerIndex <= upperIndex else { throw EvalMessage(text: "invalid range bounds") }
            return .native(RuntimeRangeValue(
                lowerBound: .native(lowerIndex),
                upperBound: .native(upperIndex),
                includesUpperBound: includesUpperBound))
        }

        throw EvalMessage(text: "invalid range bounds \(lower.stringified) and \(upper.stringified)")
    }

    private static func absorbedRangeBound(
        _ value: RuntimeValue, peer: RuntimeValue
    ) -> RuntimeValue? {
        guard let number = absorbedNumeric(value) else { return nil }
        // Fresh/zero markers adopt an integer peer so `0..<unknownCount`
        // remains the empty integer collection used throughout the corpus.
        if number == 0, peer.intValue != nil { return .native(0) }
        return .native(number)
    }
}
