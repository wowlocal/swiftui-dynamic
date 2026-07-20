import Foundation

/// The deliberately small value vocabulary that a generated host gateway may
/// return from an executor-neutral physical operation. Each case has checked
/// `Sendable` storage and a matching runtime-worker snapshot; opaque host
/// objects, interpreter values, callbacks, and mutable runtime storage are not
/// representable.
public nonisolated enum HostWorkerValue: Sendable, Equatable {
    case void
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case url(URL)
    case array([HostWorkerValue])
}

/// A statically compiled native operation whose captures are checked by the
/// Swift compiler for `Sendable`. The builder that creates this value runs on
/// the evaluator's owning actor and may copy/validate source arguments first;
/// only this closure crosses the physical-worker boundary.
public nonisolated struct HostWorkerOperation: Sendable {
    public typealias Body = @Sendable () throws -> HostWorkerValue

    private let body: Body

    public init(_ body: @escaping Body) {
        self.body = body
    }

    nonisolated func execute() throws -> HostWorkerValue {
        try body()
    }

    /// Run the same checked kernel on the owning actor and materialize the
    /// result through the same snapshot path a physical worker uses. A
    /// gateway that also executes confined uses this so both of its faces
    /// return identical runtime shapes.
    @MainActor
    public func confinedRuntimeValue() throws -> RuntimeValue {
        try execute().workerSnapshot.materializedRuntimeValue()
    }
}

extension HostWorkerValue {
    nonisolated var workerSnapshot: RuntimeWorkerValueSnapshot {
        switch self {
        case .void:
            .void
        case .bool(let value):
            .bool(value)
        case .int(let value):
            .int(value)
        case .double(let value):
            .double(value)
        case .string(let value):
            .string(value)
        case .url(let value):
            .url(value)
        case .array(let values):
            .array(values.map(\.workerSnapshot))
        }
    }
}
