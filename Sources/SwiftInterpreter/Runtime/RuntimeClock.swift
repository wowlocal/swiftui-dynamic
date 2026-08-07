import Dispatch
import Foundation

public struct RuntimeDuration: Hashable, Sendable, Comparable,
    CustomStringConvertible
{
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static func nanoseconds(_ value: Int64) -> Self {
        Self(nanoseconds: value)
    }

    public static func milliseconds(_ value: Int64) -> Self {
        Self(nanoseconds: value.multipliedClamping(by: 1_000_000))
    }

    public static func seconds(_ value: Int64) -> Self {
        Self(nanoseconds: value.multipliedClamping(by: 1_000_000_000))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public var description: String { "\(nanoseconds)ns" }
}

public struct RuntimeInstant: Hashable, Sendable, Comparable,
    CustomStringConvertible
{
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static let zero = Self(nanoseconds: 0)

    public func advanced(by duration: RuntimeDuration) -> Self {
        Self(nanoseconds: nanoseconds.addingClamping(duration.nanoseconds))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public var description: String { "instant(\(nanoseconds)ns)" }
}

/// Monotonic time owned by the interpreter runtime. Tests inject a manual
/// clock; production uses a continuous clock and never blocks an executor.
@MainActor
public protocol RuntimeClock: AnyObject {
    var now: RuntimeInstant { get }

    func sleep(
        task: RuntimeTaskID,
        until deadline: RuntimeInstant,
        tolerance: RuntimeDuration?
    ) async throws

    func cancelSleep(task: RuntimeTaskID)
}

@MainActor
public final class ContinuousRuntimeClock: RuntimeClock {
    private let clock = ContinuousClock()

    public init() {}

    public var now: RuntimeInstant {
        RuntimeInstant(nanoseconds: Int64(clamping:
            DispatchTime.now().uptimeNanoseconds))
    }

    public func sleep(
        task _: RuntimeTaskID,
        until deadline: RuntimeInstant,
        tolerance _: RuntimeDuration?
    ) async throws {
        let remaining = deadline.nanoseconds - now.nanoseconds
        guard remaining > 0 else {
            try Task.checkCancellation()
            return
        }
        try await clock.sleep(for: .nanoseconds(remaining))
    }

    public func cancelSleep(task _: RuntimeTaskID) {
        // The runtime also cancels the native driver task. ContinuousClock's
        // sleep observes that cancellation directly.
    }
}

@MainActor
public final class ManualRuntimeClock: RuntimeClock {
    private struct Sleeper {
        let deadline: RuntimeInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    public private(set) var now: RuntimeInstant
    private var sleepers: [RuntimeTaskID: Sleeper] = [:]

    public init(now: RuntimeInstant = .zero) {
        self.now = now
    }

    public var sleepingTaskCount: Int { sleepers.count }

    public func sleep(
        task: RuntimeTaskID,
        until deadline: RuntimeInstant,
        tolerance _: RuntimeDuration?
    ) async throws {
        guard deadline > now else {
            try Task.checkCancellation()
            return
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                precondition(
                    sleepers[task] == nil,
                    "a runtime task cannot register two simultaneous sleeps")
                sleepers[task] = Sleeper(
                    deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSleep(task: task)
            }
        }
    }

    public func cancelSleep(task: RuntimeTaskID) {
        sleepers.removeValue(forKey: task)?.continuation.resume(
            throwing: CancellationError())
    }

    public func advance(by duration: RuntimeDuration) {
        precondition(duration.nanoseconds >= 0, "manual time cannot move backward")
        now = now.advanced(by: duration)
        let ready = sleepers
            .filter { $0.value.deadline <= now }
            .map(\.key)
        for task in ready {
            sleepers.removeValue(forKey: task)?.continuation.resume()
        }
    }
}

// Saturating arithmetic shared with the sleep path, which converts a host
// `Duration`'s 128-bit components into the nanoseconds this runtime schedules
// in and must not trap on a value the clock can simply pin at its extreme.
extension Int64 {
    func addingClamping(_ other: Int64) -> Int64 {
        let (value, overflow) = addingReportingOverflow(other)
        guard overflow else { return value }
        return other >= 0 ? .max : .min
    }

    func multipliedClamping(by other: Int64) -> Int64 {
        let (value, overflow) = multipliedReportingOverflow(by: other)
        guard overflow else { return value }
        return (self >= 0) == (other >= 0) ? .max : .min
    }
}
