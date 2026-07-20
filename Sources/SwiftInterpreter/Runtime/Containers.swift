/// A tuple value with optional element labels: `(x: 1, y: 2)` or `(1, "a")`.
/// Members are accessed as `.0`/`.1` or by label.
@MainActor
public struct TupleValue: @preconcurrency CustomStringConvertible {
    public let labels: [String?]
    public var values: [RuntimeValue]

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
            (label.map { "\($0): " } ?? "") + value.debugStringified
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }
}

/// An order-preserving dictionary of RuntimeValues. The struct storage gives
/// assignments native value semantics; dictionary lvalues use explicit
/// read-modify-write so nested mutations propagate to their owning box.
@MainActor
public struct DictValue: @preconcurrency CustomStringConvertible {
    public private(set) var keys: [RuntimeValue] = []
    public private(set) var values: [RuntimeValue] = []

    public init() {}

    public init(keys: [RuntimeValue], values: [RuntimeValue]) {
        self.keys = keys
        self.values = values
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// Gives generated standard-library adapters the dictionary's parallel
    /// storage without exposing either array as source-level API.
    mutating func withMutableStorage(
        _ mutation: (inout [RuntimeValue], inout [RuntimeValue]) -> Void
    ) {
        var mutableKeys = keys
        var mutableValues = values
        mutation(&mutableKeys, &mutableValues)
        keys = mutableKeys
        values = mutableValues
    }

    private func matchingKeyIndex(
        _ key: RuntimeValue,
        by areEqual: (RuntimeValue, RuntimeValue) throws -> Bool
    ) throws -> Int? {
        for (index, existing) in keys.enumerated()
        where try areEqual(existing, key) {
            return index
        }
        return nil
    }

    /// Storage lookup that distinguishes an absent key from a present value
    /// whose own value is `Optional.none`.
    public func value(forKey key: RuntimeValue) throws -> RuntimeValue? {
        try value(forKey: key, by: Builtins.areEqual)
    }

    public func value(
        forKey key: RuntimeValue,
        by areEqual: (RuntimeValue, RuntimeValue) throws -> Bool
    ) throws -> RuntimeValue? {
        guard let index = try matchingKeyIndex(key, by: areEqual)
        else { return nil }
        return values[index]
    }

    /// Legacy internal lookup used by mutation/algebra paths. Source-level
    /// subscripting uses `value(forKey:)` and adds the dictionary subscript's
    /// outer Optional explicitly.
    public func lookup(_ key: RuntimeValue) throws -> RuntimeValue {
        try value(forKey: key) ?? .nilValue
    }

    public func lookup(
        _ key: RuntimeValue,
        by areEqual: (RuntimeValue, RuntimeValue) throws -> Bool
    ) throws -> RuntimeValue {
        try value(forKey: key, by: areEqual) ?? .nilValue
    }

    public mutating func update(_ key: RuntimeValue, to value: RuntimeValue) throws {
        try update(key, to: value, by: Builtins.areEqual)
    }

    public mutating func update(
        _ key: RuntimeValue,
        to value: RuntimeValue,
        by areEqual: (RuntimeValue, RuntimeValue) throws -> Bool
    ) throws {
        if let index = try matchingKeyIndex(key, by: areEqual) {
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

    /// Removes one equal-key entry and returns its prior value. Generated
    /// dictionary adapters supply the source member spelling and call shape.
    mutating func removeEntry(
        forKey key: RuntimeValue
    ) throws -> RuntimeValue? {
        try removeEntry(forKey: key, by: Builtins.areEqual)
    }

    mutating func removeEntry(
        forKey key: RuntimeValue,
        by areEqual: (RuntimeValue, RuntimeValue) throws -> Bool
    ) throws -> RuntimeValue? {
        guard let index = try matchingKeyIndex(key, by: areEqual)
        else { return nil }
        keys.remove(at: index)
        return values.remove(at: index)
    }

    /// Store a value without interpreting `Optional.none` as the dictionary
    /// subscript setter's outer nil. For `[Key: Value?]`, a typed `Value?.none`
    /// is a present value; only the untyped nil literal removes the entry.
    public mutating func setValue(
        _ key: RuntimeValue, to value: RuntimeValue
    ) throws {
        try setValue(key, to: value, by: Builtins.areEqual)
    }

    public mutating func setValue(
        _ key: RuntimeValue,
        to value: RuntimeValue,
        by areEqual: (RuntimeValue, RuntimeValue) throws -> Bool
    ) throws {
        if let index = try matchingKeyIndex(key, by: areEqual) {
            values[index] = value
            return
        }
        keys.append(key)
        values.append(value)
    }

    /// Dictionary-literal construction stores a value even when that value
    /// is an untyped nil literal; annotation resolution may subsequently
    /// turn it into `Value?.none`. Subscript assignment retains its distinct
    /// nil-means-remove behavior through `update` above.
    public mutating func setLiteralEntry(
        _ key: RuntimeValue, to value: RuntimeValue
    ) throws {
        try setValue(key, to: value)
    }

    public mutating func setLiteralEntry(
        _ key: RuntimeValue,
        to value: RuntimeValue,
        by areEqual: (RuntimeValue, RuntimeValue) throws -> Bool
    ) throws {
        try setValue(key, to: value, by: areEqual)
    }

    public var description: String {
        if keys.isEmpty { return "[:]" }
        let parts = zip(keys, values).map { "\($0.debugStringified): \($1.debugStringified)" }
        return "[" + parts.joined(separator: ", ") + "]"
    }
}
