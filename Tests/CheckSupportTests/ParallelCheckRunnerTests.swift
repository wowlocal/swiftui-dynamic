import Foundation
import Testing
@testable import CheckSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite struct ParallelCheckRunnerTests {
    @Test func parsesAndStripsRunnerOptions() throws {
        let arguments = [
            "/corpus", "--all", "--jobs", "4",
            "--shard-index", "2", "--shard-count", "4",
        ]
        let options = try ParallelCheckOptions.parse(arguments)
        let expected = try ParallelCheckOptions(
            jobs: 4, shardIndex: 2, shardCount: 4)
        #expect(options == expected)
        #expect(ParallelCheckOptions.strippingParallelOptions(from: arguments)
            == ["/corpus", "--all"])
    }

    @Test func rejectsInvalidResourceLimits() {
        #expect(throws: ParallelCheckError.self) {
            try ParallelCheckOptions.parse(["--jobs", "0"])
        }
        #expect(throws: ParallelCheckError.self) {
            try ParallelCheckOptions.parse([
                "--shard-index", "3", "--shard-count", "3",
            ])
        }
    }

    @Test func roundRobinShardingIsCompleteAndDisjoint() throws {
        let values = Array(0..<23)
        var selected: [Int] = []
        for index in 0..<4 {
            let options = try ParallelCheckOptions(
                shardIndex: index, shardCount: 4)
            let shard = options.selected(from: values)
            #expect(Set(selected).isDisjoint(with: shard))
            selected.append(contentsOf: shard)
        }
        #expect(selected.sorted() == values)
    }

    @Test func weightedShardingIsCompleteDisjointAndBalanced() throws {
        let weights = [10, 9, 8, 7, 6, 5]
        var selected: [Int] = []
        var loads: [Int] = []
        for index in 0..<2 {
            let options = try ParallelCheckOptions(
                shardIndex: index, shardCount: 2)
            let shard = options.selected(from: weights, weightedBy: { $0 })
            #expect(Set(selected).isDisjoint(with: shard))
            selected.append(contentsOf: shard)
            loads.append(shard.reduce(0, +))
        }
        #expect(selected.sorted() == weights.sorted())
        #expect(abs(loads[0] - loads[1]) <= 1)
    }

    @Test func aggregateSumsEveryCounter() throws {
        func output(_ index: Int, _ json: String) -> ParallelCheckOutput {
            ParallelCheckOutput(
                shardIndex: index,
                status: 0,
                standardOutput: "details\n@@parallel-check-summary \(json)\n",
                standardError: "")
        }
        let summary = try ParallelCheckRunner.aggregate([
            output(0, #"{"counters":{"passed":3,"total":4}}"#),
            output(1, #"{"counters":{"passed":5,"total":6}}"#),
        ])
        #expect(try summary.required("passed") == 8)
        #expect(try summary.required("total") == 10)
    }

    @Test func aggregateRejectsInconsistentCounterSchemas() {
        let outputs = [
            ParallelCheckOutput(
                shardIndex: 0,
                status: 0,
                standardOutput:
                    #"@@parallel-check-summary {"counters":{"passed":1,"total":1}}"#,
                standardError: ""),
            ParallelCheckOutput(
                shardIndex: 1,
                status: 0,
                standardOutput:
                    #"@@parallel-check-summary {"counters":{"passed":1}}"#,
                standardError: ""),
        ]
        #expect(throws: ParallelCheckError.self) {
            try ParallelCheckRunner.aggregate(outputs)
        }
    }

    @Test func aggregateRejectsDuplicateSummaries() {
        let output = ParallelCheckOutput(
            shardIndex: 3,
            status: 0,
            standardOutput: """
                @@parallel-check-summary {"counters":{"passed":1}}
                details
                @@parallel-check-summary {"counters":{"passed":1}}
                """,
            standardError: "")

        do {
            _ = try ParallelCheckRunner.aggregate([output])
            Issue.record("expected duplicate summary failure")
        } catch let error as ParallelCheckError {
            guard case .multipleSummaries(let index, let count) = error else {
                Issue.record("expected multipleSummaries, got \(error)")
                return
            }
            #expect(index == 3)
            #expect(count == 2)
        } catch {
            Issue.record("expected ParallelCheckError, got \(error)")
        }
    }

    @Test func childCrashIsPreservedByAggregation() throws {
        let outputs = try runShell(
            #"echo 'deliberate shard crash' >&2; exit 23"#)

        do {
            _ = try ParallelCheckRunner.aggregate(outputs)
            Issue.record("expected child failure")
        } catch let error as ParallelCheckError {
            guard case .childFailed(let index, let status, let diagnostics) = error
            else {
                Issue.record("expected childFailed, got \(error)")
                return
            }
            #expect(index == 0)
            #expect(status == 23)
            #expect(diagnostics.contains("deliberate shard crash"))
        }
    }

    @Test func successfulChildWithoutSummaryIsRejected() throws {
        let outputs = try runShell("exit 0")

        do {
            _ = try ParallelCheckRunner.aggregate(outputs)
            Issue.record("expected missing summary failure")
        } catch let error as ParallelCheckError {
            guard case .missingSummary(let index) = error else {
                Issue.record("expected missingSummary, got \(error)")
                return
            }
            #expect(index == 0)
        }
    }

    @Test func timeoutEscalatesToSIGKILLAndRemainsTheRootFailure() throws {
        let started = ContinuousClock.now
        let outputs = try runShell(
            #"trap '' TERM; echo 'deliberately stuck' >&2; while :; do :; done"#,
            timeout: 0.2,
            terminationGracePeriod: 0.05)
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(2))
        #expect(outputs.count == 1)
        #expect(outputs[0].timedOut)
        #expect(outputs[0].status == 9) // SIGKILL

        do {
            _ = try ParallelCheckRunner.aggregate(outputs)
            Issue.record("expected timeout failure")
        } catch let error as ParallelCheckError {
            guard case .childTimedOut(
                let index, let timeoutSeconds, let diagnostics) = error
            else {
                Issue.record("expected childTimedOut, got \(error)")
                return
            }
            #expect(index == 0)
            #expect(timeoutSeconds == 0.2)
            #expect(diagnostics.contains("deliberately stuck"))
        }
    }

    @Test func timeoutTerminatesTheDescendantProcessTree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallel-check-descendant-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidURL = directory.appendingPathComponent("pid")
        let outputs = try runShell(
            #"sh -c 'trap "" TERM; while :; do sleep 1; done' & echo $! > "$1"; wait"#,
            arguments: [pidURL.path],
            timeout: 0.2,
            terminationGracePeriod: 0.05)

        #expect(outputs.first?.timedOut == true)
        let rawPID = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let descendantPID = try #require(pid_t(rawPID))
        for _ in 0..<100 where kill(descendantPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(kill(descendantPID, 0) == -1 && errno == ESRCH)
    }

    private func runShell(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 2,
        terminationGracePeriod: TimeInterval = 0.1
    ) throws -> [ParallelCheckOutput] {
        try ParallelCheckRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            jobs: 1,
            arguments: ["-c", command, "parallel-check-test"] + arguments,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod)
    }
}
