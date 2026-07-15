import Foundation
import Testing
@testable import SwiftInterpreter

nonisolated private let cancellationRaceReplayVariable =
    "DYNAMIC_SWIFT_CANCELLATION_RACE_SEED"

private struct CancellationRaceConfigurationError: Error,
    CustomStringConvertible {
    let description: String
}

private struct CancellationRaceFailure: Error, CustomStringConvertible {
    let seed: UInt64
    let scenario: String
    let observation: String

    nonisolated var description: String {
        "cancellation race '\(scenario)' failed for seed \(seed.hex): "
            + observation + "; replay with "
            + "\(cancellationRaceReplayVariable)=\(seed.hex) "
            + "swift test --filter CancellationRaceExplorationTests"
    }
}

private struct CancellationRaceConfiguration {
    static let defaultBaseSeed: UInt64 = 0xCACE_C0DE_0000_0000
    static let defaultIterationCount = 64
    static let iterationVariable =
        "DYNAMIC_SWIFT_CANCELLATION_RACE_ITERATIONS"

    let seeds: [UInt64]
    let isReplay: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment)
        throws {
        if let rawSeed = environment[cancellationRaceReplayVariable] {
            guard let seed = UInt64.raceSeed(rawSeed) else {
                throw CancellationRaceConfigurationError(description:
                    "\(cancellationRaceReplayVariable) must be a UInt64 "
                        + "in decimal or 0x-prefixed hexadecimal form")
            }
            seeds = [seed]
            isReplay = true
            return
        }

        let iterationCount: Int
        if let rawCount = environment[Self.iterationVariable] {
            guard let parsed = Int(rawCount), (16...4_096).contains(parsed) else {
                throw CancellationRaceConfigurationError(description:
                    "\(Self.iterationVariable) must be in 16...4096")
            }
            iterationCount = parsed
        } else {
            iterationCount = Self.defaultIterationCount
        }
        seeds = (0..<iterationCount).map {
            Self.defaultBaseSeed &+ UInt64($0)
        }
        isReplay = false
    }
}

private struct CancellationRaceSchedule {
    enum CancelCompleteOrder: String {
        case cancelThenComplete
        case completeThenCancel
    }

    enum CancelWakeOrder: String {
        case cancelThenWake
        case wakeThenCancel
        case wakeThenSettleThenCancel
        case cancelThenSettleThenWake
    }

    enum HandlerOrder: String {
        case cancelThenUnregister
        case unregisterThenCancel
    }

    let seed: UInt64

    var cancelCompleteOrder: CancelCompleteOrder {
        seed & 0b1 == 0 ? .cancelThenComplete : .completeThenCancel
    }

    var cancelWakeOrder: CancelWakeOrder {
        switch (seed >> 1) & 0b11 {
        case 0: .cancelThenWake
        case 1: .wakeThenCancel
        case 2: .wakeThenSettleThenCancel
        default: .cancelThenSettleThenWake
        }
    }

    var handlerOrder: HandlerOrder {
        seed & 0b1000 == 0 ? .cancelThenUnregister : .unregisterThenCancel
    }

    var cancellationRequestCount: Int {
        Int((seed >> 4) & 0b11) + 1
    }
}

private extension UInt64 {
    nonisolated static func raceSeed(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value, radix: 10)
    }

    nonisolated var hex: String {
        String(format: "0x%016llx", self)
    }
}

@Suite("Seeded cancellation race exploration", .serialized)
struct CancellationRaceExplorationTests {
    @Test
    func configuredRaceBoardCoversEveryScheduleAndCleansUp() async throws {
        let configuration = try CancellationRaceConfiguration()
        var cancelCompleteCoverage: Set<String> = []
        var cancelWakeCoverage: Set<String> = []
        var handlerCoverage: Set<String> = []

        for seed in configuration.seeds {
            let schedule = CancellationRaceSchedule(seed: seed)
            cancelCompleteCoverage.insert(schedule.cancelCompleteOrder.rawValue)
            cancelWakeCoverage.insert(schedule.cancelWakeOrder.rawValue)
            handlerCoverage.insert(schedule.handlerOrder.rawValue)

            try exerciseCancelVersusComplete(schedule)
            try await exerciseCancelVersusWake(schedule)
            try exerciseCancelVersusHandlerUnregister(schedule)
        }

        if !configuration.isReplay {
            try require(
                cancelCompleteCoverage.count == 2,
                seed: configuration.seeds[0], scenario: "board-coverage",
                observation: "cancel/complete covered \(cancelCompleteCoverage)")
            try require(
                cancelWakeCoverage.count == 4,
                seed: configuration.seeds[0], scenario: "board-coverage",
                observation: "cancel/wake covered \(cancelWakeCoverage)")
            try require(
                handlerCoverage.count == 2,
                seed: configuration.seeds[0], scenario: "board-coverage",
                observation: "handler unregister covered \(handlerCoverage)")
        }

        print("@@cancellation-race-summary "
            + "{\"version\":1,\"iterations\":\(configuration.seeds.count),"
            + "\"firstSeed\":\"\(configuration.seeds[0].hex)\","
            + "\"replay\":\(configuration.isReplay)}")
    }

    @Test
    func failureDiagnosticContainsExactReplayCommand() {
        let failure = CancellationRaceFailure(
            seed: 0xA5, scenario: "negative-control",
            observation: "injected invariant failure")

        #expect(failure.description.contains(
            "\(cancellationRaceReplayVariable)=0x00000000000000a5"))
        #expect(failure.description.contains(
            "swift test --filter CancellationRaceExplorationTests"))
    }

    private func exerciseCancelVersusComplete(
        _ schedule: CancellationRaceSchedule
    ) throws {
        let runtime = CooperativeConcurrencyRuntime()
        let record = runtime.createTask(
            sessionID: runtime.createSession(),
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .cooperativeDefault,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        let handle = RuntimeTaskHandle(runtime: runtime, record: record)
        try require(
            handle.begin(), seed: schedule.seed,
            scenario: "cancel-versus-complete",
            observation: "fresh task did not begin")

        switch schedule.cancelCompleteOrder {
        case .cancelThenComplete:
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
            handle.succeed(with: .native("value"))
        case .completeThenCancel:
            handle.succeed(with: .native("value"))
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
        }
        runtime.release(handle.id)
        handle.cancel()

        try require(
            handle.state == .succeeded && handle.result?.stringValue == "value",
            seed: schedule.seed, scenario: "cancel-versus-complete",
            observation: "terminal outcome changed for "
                + schedule.cancelCompleteOrder.rawValue)
        try require(
            handle.isCancelled && handle.cancellation.sources == [.taskHandle],
            seed: schedule.seed, scenario: "cancel-versus-complete",
            observation: "cancellation state was not monotonic")
        try require(
            runtime.activeRecordCount == 0,
            seed: schedule.seed, scenario: "cancel-versus-complete",
            observation: "runtime retained a terminal record")
    }

    private func exerciseCancelVersusWake(
        _ schedule: CancellationRaceSchedule
    ) async throws {
        let deadline = RuntimeInstant(nanoseconds: 10)
        let clock = ManualRuntimeClock()
        let runtime = CooperativeConcurrencyRuntime(clock: clock)
        let record = runtime.createTask(
            sessionID: runtime.createSession(),
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .cooperativeDefault,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        let handle = RuntimeTaskHandle(runtime: runtime, record: record)
        try require(
            handle.begin(), seed: schedule.seed,
            scenario: "cancel-versus-wake",
            observation: "fresh task did not begin")
        runtime.suspend(record.id, for: .sleeping(until: deadline))

        let driver = Task { @MainActor [weak handle] in
            guard let handle else { return }
            do {
                try await clock.sleep(
                    task: record.id, until: deadline, tolerance: nil)
                runtime.resume(
                    record.id, from: .sleeping(until: deadline))
                handle.succeed(with: .native("awake"))
            } catch is CancellationError {
                runtime.observeCancellation(record.id)
                runtime.resume(
                    record.id, from: .sleeping(until: deadline))
                handle.succeed(with: .native("cancelled"))
            } catch {
                handle.fail(with: error)
            }
        }
        handle.attach(driver)

        for _ in 0..<1_000 where clock.sleepingTaskCount == 0 {
            await Task.yield()
        }
        try require(
            clock.sleepingTaskCount == 1,
            seed: schedule.seed, scenario: "cancel-versus-wake",
            observation: "driver did not register its manual-clock sleep")

        switch schedule.cancelWakeOrder {
        case .cancelThenWake:
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
            clock.advance(by: .nanoseconds(10))
        case .wakeThenCancel:
            clock.advance(by: .nanoseconds(10))
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
        case .wakeThenSettleThenCancel:
            clock.advance(by: .nanoseconds(10))
            await driver.value
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
        case .cancelThenSettleThenWake:
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
            await driver.value
            clock.advance(by: .nanoseconds(10))
        }
        await driver.value

        let result = handle.result?.stringValue
        let allowedResults: Set<String> = ["awake", "cancelled"]
        try require(
            result.map(allowedResults.contains) == true,
            seed: schedule.seed, scenario: "cancel-versus-wake",
            observation: "unexpected outcome \(result ?? "nil") for "
                + schedule.cancelWakeOrder.rawValue)
        if schedule.cancelWakeOrder == .cancelThenWake
            || schedule.cancelWakeOrder == .cancelThenSettleThenWake {
            try require(
                result == "cancelled",
                seed: schedule.seed, scenario: "cancel-versus-wake",
                observation: "cancel-first sleep completed normally")
        }
        if schedule.cancelWakeOrder == .wakeThenSettleThenCancel {
            try require(
                result == "awake",
                seed: schedule.seed, scenario: "cancel-versus-wake",
                observation: "settled wake lost its successful outcome")
        }
        try require(
            handle.state == .succeeded && handle.isCancelled,
            seed: schedule.seed, scenario: "cancel-versus-wake",
            observation: "task did not retain success plus cancellation")
        try require(
            handle.cancellation.isObserved == (result == "cancelled"),
            seed: schedule.seed, scenario: "cancel-versus-wake",
            observation: "observation sequence disagrees with sleep outcome")
        try require(
            clock.sleepingTaskCount == 0 && handle.suspension == nil,
            seed: schedule.seed, scenario: "cancel-versus-wake",
            observation: "sleep registration or suspension leaked")

        runtime.release(handle.id)
        try require(
            runtime.activeRecordCount == 0,
            seed: schedule.seed, scenario: "cancel-versus-wake",
            observation: "runtime retained the completed sleeper")
    }

    private func exerciseCancelVersusHandlerUnregister(
        _ schedule: CancellationRaceSchedule
    ) throws {
        let runtime = CooperativeConcurrencyRuntime()
        let record = runtime.createTask(
            sessionID: runtime.createSession(),
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .cooperativeDefault,
            taskLocals: RuntimeTaskLocalStorage(),
            name: nil)
        let handle = RuntimeTaskHandle(runtime: runtime, record: record)
        try require(
            handle.begin(), seed: schedule.seed,
            scenario: "cancel-versus-handler-unregister",
            observation: "fresh task did not begin")

        var handlerCalls = 0
        let handlerID = runtime.addCancellationHandler(to: record.id) {
            handlerCalls += 1
        }
        let expectedHandlerCalls: Int
        switch schedule.handlerOrder {
        case .cancelThenUnregister:
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
            runtime.removeCancellationHandler(handlerID, from: record.id)
            expectedHandlerCalls = 1
        case .unregisterThenCancel:
            runtime.removeCancellationHandler(handlerID, from: record.id)
            requestCancellation(of: handle, count: schedule.cancellationRequestCount)
            expectedHandlerCalls = 0
        }
        handle.cancel()
        handle.succeed(with: .native("value"))

        try require(
            handlerCalls == expectedHandlerCalls,
            seed: schedule.seed,
            scenario: "cancel-versus-handler-unregister",
            observation: "handler ran \(handlerCalls) times for "
                + schedule.handlerOrder.rawValue)
        try require(
            record.activeCancellationHandlerCount == 0,
            seed: schedule.seed,
            scenario: "cancel-versus-handler-unregister",
            observation: "handler registration leaked")
        try require(
            record.cancellationHandlerInvocationCount == expectedHandlerCalls,
            seed: schedule.seed,
            scenario: "cancel-versus-handler-unregister",
            observation: "invocation accounting diverged")

        runtime.release(handle.id)
        try require(
            handle.state == .succeeded && handle.isCancelled
                && runtime.activeRecordCount == 0,
            seed: schedule.seed,
            scenario: "cancel-versus-handler-unregister",
            observation: "terminal task or registry cleanup diverged")
    }

    private func requestCancellation(
        of handle: RuntimeTaskHandle, count: Int
    ) {
        for _ in 0..<count { handle.cancel() }
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        seed: UInt64,
        scenario: String,
        observation: @autoclosure () -> String
    ) throws {
        guard condition() else {
            throw CancellationRaceFailure(
                seed: seed, scenario: scenario,
                observation: observation())
        }
    }
}
