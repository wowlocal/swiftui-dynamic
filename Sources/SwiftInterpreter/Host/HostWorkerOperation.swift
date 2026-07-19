/// The deliberately small value vocabulary that a generated host gateway may
/// return from an executor-neutral physical operation. Each case has checked
/// `Sendable` storage and a matching runtime-worker snapshot; opaque host
/// objects, interpreter values, callbacks, and mutable runtime storage are not
/// representable.
public nonisolated enum HostWorkerValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
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
}

extension HostWorkerValue {
    nonisolated var workerSnapshot: RuntimeWorkerValueSnapshot {
        switch self {
        case .bool(let value):
            .bool(value)
        case .string(let value):
            .string(value)
        }
    }
}
