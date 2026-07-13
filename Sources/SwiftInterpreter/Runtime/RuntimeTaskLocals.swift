/// Stable identity for one runtime task-local declaration. Source-level
/// `@TaskLocal` support can later derive this from declaration identity; host
/// gateways may allocate namespaced keys today.
public struct RuntimeTaskLocalKey: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Mutable storage owned by exactly one interpreted task. Inheritance creates
/// a value-semantic snapshot rather than sharing this object with the child.
final class RuntimeTaskLocalStorage {
    private var values: [RuntimeTaskLocalKey: RuntimeValue]

    init(values: [RuntimeTaskLocalKey: RuntimeValue] = [:]) {
        self.values = values
    }

    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }

    func value(for key: RuntimeTaskLocalKey) -> RuntimeValue? {
        values[key]
    }

    func inheritedCopy() -> RuntimeTaskLocalStorage {
        RuntimeTaskLocalStorage(values: values.mapValues {
            $0.copiedForValueSemantics()
        })
    }

    func withValue<T>(
        _ value: RuntimeValue,
        for key: RuntimeTaskLocalKey,
        operation: () async throws -> T
    ) async rethrows -> T {
        let previous = values.updateValue(
            value.copiedForValueSemantics(), forKey: key)
        defer {
            if let previous {
                values[key] = previous
            } else {
                values.removeValue(forKey: key)
            }
        }
        return try await operation()
    }

    func removeAll() {
        values.removeAll(keepingCapacity: false)
    }
}
