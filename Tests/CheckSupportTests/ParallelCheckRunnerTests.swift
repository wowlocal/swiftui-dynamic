import Testing
@testable import CheckSupport

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
}
