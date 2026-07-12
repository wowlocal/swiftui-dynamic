/// Deterministic storage for an interpreted Swift `Set`.
///
/// Native `Set` needs `Hashable`, while `RuntimeValue` deliberately supports
/// dynamically interpreted equality. We therefore keep first-seen order and
/// accept an equality operation for construction and algebra. The order is an
/// implementation detail used only for deterministic iteration/description;
/// equality and set operations remain order-independent.
public struct RuntimeSetValue: CustomStringConvertible {
    public typealias Equality = (RuntimeValue, RuntimeValue) throws -> Bool

    public private(set) var elements: [RuntimeValue]
    /// Static element context when source typing provides it. This matters for
    /// empty Sets, whose element type cannot be recovered from their values.
    public let elementTypeName: String?

    /// Construct from elements already known to be unique under the runtime's
    /// equality relation. Use `deduplicating` for external input.
    public init(
        uniqueElements: [RuntimeValue] = [], elementTypeName: String? = nil
    ) {
        self.elements = uniqueElements
        self.elementTypeName = elementTypeName
    }

    public static func deduplicating(
        _ values: [RuntimeValue], elementTypeName: String? = nil,
        by areEqual: Equality
    ) throws -> RuntimeSetValue {
        var result = RuntimeSetValue(elementTypeName: elementTypeName)
        for value in values {
            _ = try result.insert(value, by: areEqual)
        }
        return result
    }

    public func contains(
        _ value: RuntimeValue, by areEqual: Equality
    ) throws -> Bool {
        for element in elements where try areEqual(element, value) {
            return true
        }
        return false
    }

    @discardableResult
    public mutating func insert(
        _ value: RuntimeValue, by areEqual: Equality
    ) throws -> (inserted: Bool, memberAfterInsert: RuntimeValue) {
        for element in elements where try areEqual(element, value) {
            return (false, element)
        }
        elements.append(value)
        return (true, value)
    }

    public mutating func remove(
        _ value: RuntimeValue, by areEqual: Equality
    ) throws -> RuntimeValue? {
        for (index, element) in elements.enumerated()
        where try areEqual(element, value) {
            return elements.remove(at: index)
        }
        return nil
    }

    public func isEqual(
        to other: RuntimeSetValue, by areEqual: Equality
    ) throws -> Bool {
        guard elements.count == other.elements.count else { return false }
        for element in elements where try !other.contains(element, by: areEqual) {
            return false
        }
        return true
    }

    public func union(
        _ other: [RuntimeValue], by areEqual: Equality
    ) throws -> RuntimeSetValue {
        var result = self
        for element in other {
            _ = try result.insert(element, by: areEqual)
        }
        return result
    }

    public func intersection(
        _ other: [RuntimeValue], by areEqual: Equality
    ) throws -> RuntimeSetValue {
        var kept: [RuntimeValue] = []
        for element in elements {
            var present = false
            for candidate in other where try areEqual(element, candidate) {
                present = true
                break
            }
            if present { kept.append(element) }
        }
        return RuntimeSetValue(
            uniqueElements: kept, elementTypeName: elementTypeName)
    }

    public func subtracting(
        _ other: [RuntimeValue], by areEqual: Equality
    ) throws -> RuntimeSetValue {
        var kept: [RuntimeValue] = []
        for element in elements {
            var present = false
            for candidate in other where try areEqual(element, candidate) {
                present = true
                break
            }
            if !present { kept.append(element) }
        }
        return RuntimeSetValue(
            uniqueElements: kept, elementTypeName: elementTypeName)
    }

    public func symmetricDifference(
        _ other: [RuntimeValue], by areEqual: Equality
    ) throws -> RuntimeSetValue {
        let left = try subtracting(other, by: areEqual)
        let right = try RuntimeSetValue.deduplicating(other, by: areEqual)
            .subtracting(elements, by: areEqual)
        return try left.union(right.elements, by: areEqual)
    }

    public var description: String {
        let rendered = elements.map(\.stringified).sorted()
        return "Set([" + rendered.joined(separator: ", ") + "])"
    }
}
