import Foundation
import Testing
@testable import SwiftInterpreter

nonisolated private let structuredCancellationReplayVariable =
    "DYNAMIC_SWIFT_STRUCTURED_CANCELLATION_SEED"

private struct StructuredCancellationConfigurationError: Error,
    CustomStringConvertible {
    let description: String
}

private struct StructuredCancellationFailure: Error, CustomStringConvertible {
    let seed: UInt64
    let scenario: String
    let observation: String

    nonisolated var description: String {
        "structured cancellation storm '\(scenario)' failed for seed "
            + "\(seed.structuredStressHex): \(observation); replay with "
            + "\(structuredCancellationReplayVariable)="
            + "\(seed.structuredStressHex) swift test --filter "
            + "StructuredCancellationStressTests"
    }
}

private struct StructuredCancellationConfiguration {
    static let defaultBaseSeed: UInt64 = 0x57AC_CE11_0000_0000
    static let defaultIterationCount = 64
    static let iterationVariable =
        "DYNAMIC_SWIFT_STRUCTURED_CANCELLATION_ITERATIONS"

    let seeds: [UInt64]
    let isReplay: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment)
        throws {
        if let rawSeed = environment[structuredCancellationReplayVariable] {
            guard let seed = UInt64.structuredStressSeed(rawSeed) else {
                throw StructuredCancellationConfigurationError(description:
                    "\(structuredCancellationReplayVariable) must be a UInt64 "
                        + "in decimal or 0x-prefixed hexadecimal form")
            }
            seeds = [seed]
            isReplay = true
            return
        }

        let iterationCount: Int
        if let rawCount = environment[Self.iterationVariable] {
            guard let parsed = Int(rawCount), (64...4_096).contains(parsed) else {
                throw StructuredCancellationConfigurationError(description:
                    "\(Self.iterationVariable) must be in 64...4096")
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

private struct StructuredCancellationSchedule {
    let seed: UInt64

    var fanout: Int {
        8 + Int(seed & 0b111)
    }

    var cancelBeforeAdding: Bool {
        (seed >> 3) & 0b1 == 0
    }

    var cancellationRequestCount: Int {
        1 + Int((seed >> 4) & 0b11)
    }

    var scenario: String {
        let phase = cancelBeforeAdding ? "before-add" : "after-start"
        return "\(phase)-fanout-\(fanout)-requests-"
            + "\(cancellationRequestCount)"
    }
}

private extension UInt64 {
    nonisolated static func structuredStressSeed(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value, radix: 10)
    }

    nonisolated var structuredStressHex: String {
        String(format: "0x%016llx", self)
    }
}

@Suite("Seeded structured cancellation stress", .serialized)
struct StructuredCancellationStressTests {
    @Test
    func configuredStormBoardDrainsEveryChildAndCleansUp() async throws {
        let configuration = try StructuredCancellationConfiguration()
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-group-cancellation-storm.swift")
        let declarations = try String(contentsOf: fixture, encoding: .utf8)
        let interpreter = Interpreter()
        var fanoutCoverage: Set<Int> = []
        var phaseCoverage: Set<Bool> = []
        var requestCountCoverage: Set<Int> = []

        for (iteration, seed) in configuration.seeds.enumerated() {
            let schedule = StructuredCancellationSchedule(seed: seed)
            fanoutCoverage.insert(schedule.fanout)
            phaseCoverage.insert(schedule.cancelBeforeAdding)
            requestCountCoverage.insert(schedule.cancellationRequestCount)
            let entry = "await taskGroupCancellationStorm(fanout: "
                + "\(schedule.fanout), cancelBeforeAdding: "
                + "\(schedule.cancelBeforeAdding), cancellationRequestCount: "
                + "\(schedule.cancellationRequestCount))"
            let source = iteration == 0
                ? declarations + "\n" + entry + "\n"
                : entry + "\n"

            let result: RuntimeValue
            do {
                result = try await interpreter.runAsync(source: source)
            } catch {
                throw StructuredCancellationFailure(
                    seed: seed, scenario: schedule.scenario,
                    observation: "interpreter threw \(error)")
            }

            try require(
                result.stringValue == "\(schedule.fanout):"
                    + "\(schedule.fanout):cancelled:owner-active",
                seed: seed, scenario: schedule.scenario,
                observation: "unexpected result \(result)")
            try require(
                interpreter.concurrencyRuntime.activeRecordCount == 0
                    && interpreter.concurrencyRuntime
                        .activeStructuredScopeCount == 0
                    && interpreter.concurrencyRuntime.activeTaskGroupCount == 0
                    && interpreter.concurrencyRuntime
                        .activeHostOperationCount == 0
                    && interpreter.scheduledTasks.isEmpty,
                seed: seed, scenario: schedule.scenario,
                observation: "runtime registries were not empty after drain")
        }

        if !configuration.isReplay {
            try require(
                fanoutCoverage == Set(8...15),
                seed: configuration.seeds[0], scenario: "board-coverage",
                observation: "fanouts covered \(fanoutCoverage.sorted())")
            try require(
                phaseCoverage == [false, true],
                seed: configuration.seeds[0], scenario: "board-coverage",
                observation: "phases covered \(phaseCoverage)")
            try require(
                requestCountCoverage == Set(1...4),
                seed: configuration.seeds[0], scenario: "board-coverage",
                observation: "request counts covered "
                    + "\(requestCountCoverage.sorted())")
        }

        print("@@structured-cancellation-stress-summary "
            + "{\"version\":1,\"iterations\":\(configuration.seeds.count),"
            + "\"firstSeed\":\"\(configuration.seeds[0].structuredStressHex)\","
            + "\"replay\":\(configuration.isReplay)}")
    }

    @Test
    func failureDiagnosticContainsExactReplayCommand() {
        let failure = StructuredCancellationFailure(
            seed: 0xA5, scenario: "negative-control",
            observation: "injected invariant failure")

        #expect(failure.description.contains(
            "\(structuredCancellationReplayVariable)=0x00000000000000a5"))
        #expect(failure.description.contains(
            "swift test --filter StructuredCancellationStressTests"))
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        seed: UInt64,
        scenario: String,
        observation: @autoclosure () -> String
    ) throws {
        guard condition() else {
            throw StructuredCancellationFailure(
                seed: seed, scenario: scenario,
                observation: observation())
        }
    }
}
