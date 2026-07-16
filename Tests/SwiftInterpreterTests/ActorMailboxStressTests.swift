import Foundation
import Testing
@testable import SwiftInterpreter

nonisolated private let actorMailboxStressReplayVariable =
    "DYNAMIC_SWIFT_ACTOR_MAILBOX_STRESS_SEED"

private struct ActorMailboxStressConfigurationError: Error,
    CustomStringConvertible {
    let description: String
}

private struct ActorMailboxStressFailure: Error, CustomStringConvertible {
    let seed: UInt64
    let scenario: String
    let observation: String

    nonisolated var description: String {
        "actor mailbox stress '\(scenario)' failed for seed "
            + "\(seed.actorMailboxStressHex): \(observation); replay with "
            + "\(actorMailboxStressReplayVariable)="
            + "\(seed.actorMailboxStressHex) swift test --filter "
            + "ActorMailboxStressTests"
    }
}

private struct ActorMailboxStressConfiguration {
    static let defaultBaseSeed: UInt64 = 0xAC70_5EED_0000_0000
    static let defaultIterationCount = 64
    static let iterationVariable =
        "DYNAMIC_SWIFT_ACTOR_MAILBOX_STRESS_ITERATIONS"

    let seeds: [UInt64]
    let isReplay: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment)
        throws
    {
        if let rawSeed = environment[actorMailboxStressReplayVariable] {
            guard let seed = UInt64.actorMailboxStressSeed(rawSeed) else {
                throw ActorMailboxStressConfigurationError(description:
                    "\(actorMailboxStressReplayVariable) must be a UInt64 "
                        + "in decimal or 0x-prefixed hexadecimal form")
            }
            seeds = [seed]
            isReplay = true
            return
        }

        let iterationCount: Int
        if let rawCount = environment[Self.iterationVariable] {
            guard let parsed = Int(rawCount), (64...4_096).contains(parsed) else {
                throw ActorMailboxStressConfigurationError(description:
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

private struct ActorMailboxStressSchedule {
    let seed: UInt64

    var fanout: Int {
        2 + Int(seed & 0b111)
    }

    var rounds: Int {
        2 + Int((seed >> 3) & 0b11)
    }

    var resumeYieldCount: Int {
        Int((seed >> 4) & 0b11)
    }

    var yieldBeforeCall: Bool {
        (seed >> 5) & 0b1 == 1
    }

    var expected: String {
        "\(fanout * rounds):\(rounds):0:0:\(fanout)"
    }

    var scenario: String {
        "fanout-\(fanout)-rounds-\(rounds)-resume-yields-"
            + "\(resumeYieldCount)-pre-yield-\(yieldBeforeCall)"
    }
}

private extension UInt64 {
    nonisolated static func actorMailboxStressSeed(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value, radix: 10)
    }

    nonisolated var actorMailboxStressHex: String {
        String(format: "0x%016llx", self)
    }
}

@Suite("Seeded actor mailbox stress", .serialized)
struct ActorMailboxStressTests {
    @Test
    func configuredBoardPreservesOwnershipAndDrainsEveryEdge() async throws {
        let configuration = try ActorMailboxStressConfiguration()
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("actor-mailbox-stress.swift")
        let declarations = try String(contentsOf: fixture, encoding: .utf8)
        let interpreter = Interpreter()
        interpreter.globals.define(
            "parityActorSegmentOwnership",
            .hostFunction(HostFunction(
                name: "parityActorSegmentOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID else {
                    return .native("unowned")
                }
                let owner = interpreter.concurrencyRuntime.actors[actorID]?
                    .executorOwnerTaskID
                return .native(owner == taskID ? "owned" : "unowned")
            }))
        var fanoutCoverage: Set<Int> = []
        var roundCoverage: Set<Int> = []
        var resumeYieldCoverage: Set<Int> = []
        var preYieldCoverage: Set<Bool> = []

        for (iteration, seed) in configuration.seeds.enumerated() {
            let schedule = ActorMailboxStressSchedule(seed: seed)
            fanoutCoverage.insert(schedule.fanout)
            roundCoverage.insert(schedule.rounds)
            resumeYieldCoverage.insert(schedule.resumeYieldCount)
            preYieldCoverage.insert(schedule.yieldBeforeCall)
            let entry = "await actorMailboxStress(fanout: "
                + "\(schedule.fanout), rounds: \(schedule.rounds), "
                + "resumeYieldCount: \(schedule.resumeYieldCount), "
                + "yieldBeforeCall: \(schedule.yieldBeforeCall))"
            let source = iteration == 0
                ? declarations + "\n" + entry + "\n"
                : entry + "\n"

            let result: RuntimeValue
            do {
                result = try await interpreter.runAsync(source: source)
            } catch {
                throw ActorMailboxStressFailure(
                    seed: seed,
                    scenario: schedule.scenario,
                    observation: "interpreter threw \(error)")
            }

            try require(
                result.stringValue == schedule.expected,
                seed: seed,
                scenario: schedule.scenario,
                observation: "unexpected result \(result)")
            try require(
                interpreter.concurrencyRuntime.activeRecordCount == 0
                    && interpreter.concurrencyRuntime.activeActorCount == 0
                    && interpreter.concurrencyRuntime
                        .activeStructuredScopeCount == 0
                    && interpreter.concurrencyRuntime.activeTaskGroupCount == 0
                    && interpreter.concurrencyRuntime
                        .activeHostOperationCount == 0
                    && interpreter.scheduledTasks.isEmpty,
                seed: seed,
                scenario: schedule.scenario,
                observation: "runtime registries were not empty after drain")
        }

        if !configuration.isReplay {
            try require(
                fanoutCoverage == Set(2...9),
                seed: configuration.seeds[0],
                scenario: "board-coverage",
                observation: "fanouts covered \(fanoutCoverage.sorted())")
            try require(
                roundCoverage == Set(2...5),
                seed: configuration.seeds[0],
                scenario: "board-coverage",
                observation: "rounds covered \(roundCoverage.sorted())")
            try require(
                resumeYieldCoverage == Set(0...3),
                seed: configuration.seeds[0],
                scenario: "board-coverage",
                observation: "resume yields covered "
                    + "\(resumeYieldCoverage.sorted())")
            try require(
                preYieldCoverage == [false, true],
                seed: configuration.seeds[0],
                scenario: "board-coverage",
                observation: "pre-yield modes covered \(preYieldCoverage)")
        }

        print("@@actor-mailbox-stress-summary "
            + "{\"version\":1,\"iterations\":\(configuration.seeds.count),"
            + "\"firstSeed\":\""
            + "\(configuration.seeds[0].actorMailboxStressHex)\","
            + "\"replay\":\(configuration.isReplay)}")
    }

    @Test
    func failureDiagnosticContainsExactReplayCommand() {
        let failure = ActorMailboxStressFailure(
            seed: 0xA5,
            scenario: "negative-control",
            observation: "injected invariant failure")

        #expect(failure.description.contains(
            "\(actorMailboxStressReplayVariable)=0x00000000000000a5"))
        #expect(failure.description.contains(
            "swift test --filter ActorMailboxStressTests"))
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        seed: UInt64,
        scenario: String,
        observation: @autoclosure () -> String
    ) throws {
        guard condition() else {
            throw ActorMailboxStressFailure(
                seed: seed,
                scenario: scenario,
                observation: observation())
        }
    }
}
