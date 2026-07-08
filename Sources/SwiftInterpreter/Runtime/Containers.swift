/// A tuple value with optional element labels: `(x: 1, y: 2)` or `(1, "a")`.
/// Members are accessed as `.0`/`.1` or by label.
public final class TupleValue: CustomStringConvertible {
    public let labels: [String?]
    public let values: [RuntimeValue]

    public init(labels: [String?], values: [RuntimeValue]) {
        self.labels = labels
        self.values = values
    }

    public func value(for member: String) -> RuntimeValue? {
        if let index = Int(member), values.indices.contains(index) { return values[index] }
        if let index = labels.firstIndex(of: member) { return values[index] }
        return nil
    }

    public var description: String {
        let parts = zip(labels, values).map { label, value in
            (label.map { "\($0): " } ?? "") + value.stringified
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }
}

/// An order-preserving dictionary of RuntimeValues. Reference-backed (like all
/// interpreted containers that need in-place mutation through `subscript =`).
public final class DictValue: CustomStringConvertible {
    public private(set) var keys: [RuntimeValue] = []
    public private(set) var values: [RuntimeValue] = []

    public init() {}

    public init(keys: [RuntimeValue], values: [RuntimeValue]) {
        self.keys = keys
        self.values = values
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func lookup(_ key: RuntimeValue) throws -> RuntimeValue {
        for (index, existing) in keys.enumerated() where try Builtins.areEqual(existing, key) {
            return values[index]
        }
        return .nilValue
    }

    public func update(_ key: RuntimeValue, to value: RuntimeValue) throws {
        for (index, existing) in keys.enumerated() where try Builtins.areEqual(existing, key) {
            if value.isNil {
                keys.remove(at: index)
                values.remove(at: index)
            } else {
                values[index] = value
            }
            return
        }
        if !value.isNil {
            keys.append(key)
            values.append(value)
        }
    }

    public var description: String {
        if keys.isEmpty { return "[:]" }
        let parts = zip(keys, values).map { "\($0.stringified): \($1.stringified)" }
        return "[" + parts.joined(separator: ", ") + "]"
    }
}
