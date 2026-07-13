import Foundation

public enum ParallelCheckError: Error, CustomStringConvertible {
    case invalidOption(String)
    case childFailed(index: Int, status: Int32, diagnostics: String)
    case missingSummary(index: Int)
    case malformedSummary(index: Int, line: String)
    case inconsistentCounters(index: Int, expected: [String], actual: [String])
    case missingCounter(String)

    public var description: String {
        switch self {
        case .invalidOption(let message):
            return message
        case .childFailed(let index, let status, let diagnostics):
            return "check shard \(index) exited with status \(status): \(diagnostics)"
        case .missingSummary(let index):
            return "check shard \(index) did not emit a machine-readable summary"
        case .malformedSummary(let index, let line):
            return "check shard \(index) emitted a malformed summary: \(line)"
        case .inconsistentCounters(let index, let expected, let actual):
            return "check shard \(index) counters \(actual) do not match \(expected)"
        case .missingCounter(let name):
            return "parallel check summary is missing required counter '\(name)'"
        }
    }
}

/// Process-level parallelism options shared by the repository's check tools.
///
/// The check binaries intentionally do not evaluate multiple programs inside
/// one process. The interpreter and UI bridge are MainActor-isolated and some
/// check scenarios install process-global replay state. Separate processes
/// provide real CPU parallelism while preserving those isolation boundaries.
public struct ParallelCheckOptions: Equatable, Sendable {
    public let jobs: Int
    public let shardIndex: Int
    public let shardCount: Int

    public init(jobs: Int = 1, shardIndex: Int = 0, shardCount: Int = 1) throws {
        guard jobs > 0 else {
            throw ParallelCheckError.invalidOption("--jobs must be greater than zero")
        }
        guard shardCount > 0 else {
            throw ParallelCheckError.invalidOption("--shard-count must be greater than zero")
        }
        guard shardIndex >= 0, shardIndex < shardCount else {
            throw ParallelCheckError.invalidOption(
                "--shard-index must be in 0..<--shard-count")
        }
        self.jobs = jobs
        self.shardIndex = shardIndex
        self.shardCount = shardCount
    }

    public static func parse(_ arguments: [String]) throws -> ParallelCheckOptions {
        var jobs = 1
        var shardIndex = 0
        var shardCount = 1
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--jobs":
                jobs = try integer(after: index, option: "--jobs", in: arguments)
                index += 2
            case "--shard-index":
                shardIndex = try integer(
                    after: index, option: "--shard-index", in: arguments)
                index += 2
            case "--shard-count":
                shardCount = try integer(
                    after: index, option: "--shard-count", in: arguments)
                index += 2
            default:
                index += 1
            }
        }
        return try ParallelCheckOptions(
            jobs: jobs, shardIndex: shardIndex, shardCount: shardCount)
    }

    public var shouldCoordinate: Bool {
        jobs > 1 && shardCount == 1
    }

    public func selected<Element>(from elements: [Element]) -> [Element] {
        guard shardCount > 1 else { return elements }
        return elements.enumerated().compactMap { offset, element in
            offset % shardCount == shardIndex ? element : nil
        }
    }

    /// Deterministic longest-processing-time assignment using a stable work
    /// proxy. Every process reconstructs the same assignment independently;
    /// selected elements retain their original order within a shard.
    public func selected<Element>(
        from elements: [Element],
        weightedBy weight: (Element) -> Int
    ) -> [Element] {
        guard shardCount > 1 else { return elements }
        let weights = elements.map { max(1, weight($0)) }
        let descendingIndices = elements.indices.sorted { lhs, rhs in
            if weights[lhs] != weights[rhs] {
                return weights[lhs] > weights[rhs]
            }
            return lhs < rhs
        }
        var loads = Array(repeating: UInt64(0), count: shardCount)
        var owners = Array(repeating: 0, count: elements.count)
        for elementIndex in descendingIndices {
            let worker = loads.indices.min { lhs, rhs in
                if loads[lhs] != loads[rhs] { return loads[lhs] < loads[rhs] }
                return lhs < rhs
            }!
            owners[elementIndex] = worker
            let itemWeight = UInt64(weights[elementIndex])
            loads[worker] = UInt64.max - loads[worker] < itemWeight
                ? UInt64.max
                : loads[worker] + itemWeight
        }
        return elements.indices.compactMap { index in
            owners[index] == shardIndex ? elements[index] : nil
        }
    }

    /// Returns the check-specific arguments, removing all parallel-runner
    /// options so a coordinator can append canonical child shard options.
    public static func strippingParallelOptions(from arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--jobs", "--shard-index", "--shard-count":
                index += min(2, arguments.count - index)
            default:
                result.append(arguments[index])
                index += 1
            }
        }
        return result
    }

    private static func integer(
        after index: Int,
        option: String,
        in arguments: [String]
    ) throws -> Int {
        guard arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1]) else {
            throw ParallelCheckError.invalidOption("\(option) requires an integer value")
        }
        return value
    }
}

public struct ParallelCheckSummary: Codable, Equatable, Sendable {
    public let counters: [String: Int]

    public init(_ counters: [String: Int]) {
        self.counters = counters
    }

    public func required(_ counter: String) throws -> Int {
        guard let value = counters[counter] else {
            throw ParallelCheckError.missingCounter(counter)
        }
        return value
    }
}

public struct ParallelCheckOutput: Sendable {
    public let shardIndex: Int
    public let status: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum ParallelCheckRunner {
    private static let summaryPrefix = "@@parallel-check-summary "

    /// Starts every child before waiting for any child, so the workers execute
    /// concurrently without requiring shared mutable Swift state.
    public static func runSelf(
        jobs: Int,
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) throws -> [ParallelCheckOutput] {
        guard jobs > 1 else { return [] }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dynamic-swift-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseArguments = ParallelCheckOptions.strippingParallelOptions(
            from: arguments)
        var children: [ChildProcess] = []
        do {
            for shardIndex in 0..<jobs {
                let stdoutURL = directory.appendingPathComponent("\(shardIndex).stdout")
                let stderrURL = directory.appendingPathComponent("\(shardIndex).stderr")
                _ = FileManager.default.createFile(
                    atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(
                    atPath: stderrURL.path, contents: nil)
                let stdout = try FileHandle(forWritingTo: stdoutURL)
                let stderr = try FileHandle(forWritingTo: stderrURL)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = baseArguments + [
                    "--jobs", "1",
                    "--shard-index", String(shardIndex),
                    "--shard-count", String(jobs),
                ]
                process.currentDirectoryURL = URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true)
                process.environment = ProcessInfo.processInfo.environment
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    try? stdout.close()
                    try? stderr.close()
                    throw error
                }
                children.append(ChildProcess(
                    shardIndex: shardIndex,
                    process: process,
                    stdout: stdout,
                    stderr: stderr,
                    stdoutURL: stdoutURL,
                    stderrURL: stderrURL))
            }
        } catch {
            for child in children where child.process.isRunning {
                child.process.terminate()
            }
            for child in children {
                child.process.waitUntilExit()
                try? child.stdout.close()
                try? child.stderr.close()
            }
            throw error
        }

        var outputs: [ParallelCheckOutput] = []
        for child in children {
            child.process.waitUntilExit()
            try? child.stdout.synchronize()
            try? child.stderr.synchronize()
            try? child.stdout.close()
            try? child.stderr.close()
            outputs.append(ParallelCheckOutput(
                shardIndex: child.shardIndex,
                status: child.process.terminationStatus,
                standardOutput: (try? String(
                    contentsOf: child.stdoutURL, encoding: .utf8)) ?? "",
                standardError: (try? String(
                    contentsOf: child.stderrURL, encoding: .utf8)) ?? ""))
        }
        return outputs.sorted { $0.shardIndex < $1.shardIndex }
    }

    public static func emit(_ summary: ParallelCheckSummary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(summary),
              let json = String(data: data, encoding: .utf8) else { return }
        print(summaryPrefix + json)
    }

    public static func aggregate(
        _ outputs: [ParallelCheckOutput]
    ) throws -> ParallelCheckSummary {
        var counters: [String: Int] = [:]
        var expectedCounterNames: Set<String>?
        for output in outputs {
            guard output.status == 0 else {
                let diagnostics = output.standardError.isEmpty
                    ? String(output.standardOutput.suffix(2_000))
                    : String(output.standardError.suffix(2_000))
                throw ParallelCheckError.childFailed(
                    index: output.shardIndex,
                    status: output.status,
                    diagnostics: diagnostics)
            }
            let lines = output.standardOutput.split(
                separator: "\n", omittingEmptySubsequences: false)
            guard let line = lines.last(where: { $0.hasPrefix(summaryPrefix) }) else {
                throw ParallelCheckError.missingSummary(index: output.shardIndex)
            }
            let json = line.dropFirst(summaryPrefix.count)
            guard let data = String(json).data(using: .utf8),
                  let summary = try? JSONDecoder().decode(
                    ParallelCheckSummary.self, from: data) else {
                throw ParallelCheckError.malformedSummary(
                    index: output.shardIndex, line: String(line))
            }
            let counterNames = Set(summary.counters.keys)
            if let expectedCounterNames,
               counterNames != expectedCounterNames {
                throw ParallelCheckError.inconsistentCounters(
                    index: output.shardIndex,
                    expected: expectedCounterNames.sorted(),
                    actual: counterNames.sorted())
            }
            expectedCounterNames = counterNames
            for (name, value) in summary.counters {
                counters[name, default: 0] += value
            }
        }
        return ParallelCheckSummary(counters)
    }

    public static func replay(_ outputs: [ParallelCheckOutput]) {
        for output in outputs {
            let text = output.standardOutput.split(
                separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix(summaryPrefix) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                print("── shard \(output.shardIndex + 1)/\(outputs.count) ──")
                print(text)
            }
            let diagnostics = output.standardError.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !diagnostics.isEmpty {
                FileHandle.standardError.write(Data(
                    "shard \(output.shardIndex + 1):\n\(diagnostics)\n".utf8))
            }
        }
    }
}

private struct ChildProcess {
    let shardIndex: Int
    let process: Process
    let stdout: FileHandle
    let stderr: FileHandle
    let stdoutURL: URL
    let stderrURL: URL
}
