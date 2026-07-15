import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ParallelCheckError: Error, CustomStringConvertible {
    case invalidOption(String)
    case childFailed(index: Int, status: Int32, diagnostics: String)
    case childTimedOut(index: Int, timeoutSeconds: TimeInterval, diagnostics: String)
    case missingSummary(index: Int)
    case multipleSummaries(index: Int, count: Int)
    case malformedSummary(index: Int, line: String)
    case inconsistentCounters(index: Int, expected: [String], actual: [String])
    case missingCounter(String)

    public var description: String {
        switch self {
        case .invalidOption(let message):
            return message
        case .childFailed(let index, let status, let diagnostics):
            return "check shard \(index) exited with status \(status): \(diagnostics)"
        case .childTimedOut(let index, let timeoutSeconds, let diagnostics):
            let timeout = timeoutSeconds.formatted(
                .number.precision(.fractionLength(0...3)))
            return "check shard \(index) exceeded its \(timeout)-second deadline: \(diagnostics)"
        case .missingSummary(let index):
            return "check shard \(index) did not emit a machine-readable summary"
        case .multipleSummaries(let index, let count):
            return "check shard \(index) emitted \(count) machine-readable summaries; expected one"
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
    public let timeoutSeconds: TimeInterval?

    public var timedOut: Bool { timeoutSeconds != nil }

    public init(
        shardIndex: Int,
        status: Int32,
        standardOutput: String,
        standardError: String,
        timeoutSeconds: TimeInterval? = nil
    ) {
        self.shardIndex = shardIndex
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum ParallelCheckRunner {
    private static let summaryPrefix = "@@parallel-check-summary "
    private static let timeoutEnvironmentVariable =
        "DYNAMIC_SWIFT_CHECK_TIMEOUT_SECONDS"
    private static let defaultTimeout: TimeInterval = 30 * 60

    /// Starts every child before waiting for any child, so the workers execute
    /// concurrently without requiring shared mutable Swift state.
    public static func runSelf(
        jobs: Int,
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        timeout: TimeInterval? = nil,
        terminationGracePeriod: TimeInterval = 2
    ) throws -> [ParallelCheckOutput] {
        guard jobs > 1 else { return [] }

        let childTimeout: TimeInterval
        if let timeout {
            childTimeout = timeout
        } else if let configured = ProcessInfo.processInfo.environment[
            timeoutEnvironmentVariable]
        {
            guard let value = TimeInterval(configured), value.isFinite, value > 0 else {
                throw ParallelCheckError.invalidOption(
                    "\(timeoutEnvironmentVariable) must be a positive number, got '\(configured)'")
            }
            childTimeout = value
        } else {
            childTimeout = defaultTimeout
        }

        return try run(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            jobs: jobs,
            arguments: arguments,
            currentDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true),
            environment: ProcessInfo.processInfo.environment,
            timeout: childTimeout,
            terminationGracePeriod: terminationGracePeriod)
    }

    /// Runs a sharded executable under one deadline per child. This internal
    /// entry point also lets CheckSupport exercise crash and timeout behavior
    /// without recursively launching its own test bundle.
    static func run(
        executableURL: URL,
        jobs: Int,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval = 2
    ) throws -> [ParallelCheckOutput] {
        guard jobs > 0 else {
            throw ParallelCheckError.invalidOption("jobs must be greater than zero")
        }
        guard timeout.isFinite, timeout > 0 else {
            throw ParallelCheckError.invalidOption("child timeout must be a positive number")
        }
        guard terminationGracePeriod.isFinite, terminationGracePeriod >= 0 else {
            throw ParallelCheckError.invalidOption(
                "termination grace period must be a nonnegative number")
        }

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
                process.executableURL = executableURL
                process.arguments = baseArguments + [
                    "--jobs", "1",
                    "--shard-index", String(shardIndex),
                    "--shard-count", String(jobs),
                ]
                process.currentDirectoryURL = currentDirectoryURL
                process.environment = environment
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
                    stderrURL: stderrURL,
                    startedAt: ProcessInfo.processInfo.systemUptime))
            }
        } catch {
            terminate(children, gracePeriod: terminationGracePeriod)
            for child in children {
                child.process.waitUntilExit()
                try? child.stdout.close()
                try? child.stderr.close()
            }
            throw error
        }

        var timedOutShardIndices: Set<Int> = []
        while children.contains(where: { $0.process.isRunning }) {
            let now = ProcessInfo.processInfo.systemUptime
            let overdue = children.filter {
                $0.process.isRunning && now - $0.startedAt >= timeout
            }
            if !overdue.isEmpty {
                timedOutShardIndices.formUnion(overdue.map(\.shardIndex))
                // Once one shard exceeds its deadline, the aggregate result is
                // already invalid. Stop siblings too so a second stuck shard
                // cannot extend the coordinator's failure path.
                terminate(
                    children.filter { $0.process.isRunning },
                    gracePeriod: terminationGracePeriod)
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
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
                    contentsOf: child.stderrURL, encoding: .utf8)) ?? "",
                timeoutSeconds: timedOutShardIndices.contains(child.shardIndex)
                    ? timeout
                    : nil))
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
        // Check timeouts before statuses because siblings are deliberately
        // terminated when one shard times out. The deadline is the root cause.
        if let output = outputs.first(where: \.timedOut) {
            throw ParallelCheckError.childTimedOut(
                index: output.shardIndex,
                timeoutSeconds: output.timeoutSeconds ?? 0,
                diagnostics: diagnostics(for: output))
        }
        var counters: [String: Int] = [:]
        var expectedCounterNames: Set<String>?
        for output in outputs {
            guard output.status == 0 else {
                throw ParallelCheckError.childFailed(
                    index: output.shardIndex,
                    status: output.status,
                    diagnostics: diagnostics(for: output))
            }
            let lines = output.standardOutput.split(
                separator: "\n", omittingEmptySubsequences: false)
            let summaryLines = lines.filter { $0.hasPrefix(summaryPrefix) }
            guard !summaryLines.isEmpty else {
                throw ParallelCheckError.missingSummary(index: output.shardIndex)
            }
            guard summaryLines.count == 1 else {
                throw ParallelCheckError.multipleSummaries(
                    index: output.shardIndex, count: summaryLines.count)
            }
            let line = summaryLines[0]
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

    private static func diagnostics(for output: ParallelCheckOutput) -> String {
        output.standardError.isEmpty
            ? String(output.standardOutput.suffix(2_000))
            : String(output.standardError.suffix(2_000))
    }

    private static func terminate(
        _ children: [ChildProcess],
        gracePeriod: TimeInterval
    ) {
        // Snapshot descendants before TERM. If a parent exits first, an
        // uncooperative descendant is reparented and can no longer be found by
        // walking the original tree during escalation.
        let processIdentities = children.flatMap { child in
            descendantProcessIdentifiers(of: child.process.processIdentifier)
                + [child.process.processIdentifier]
        }.compactMap { processIdentity(for: $0) }
        for identity in processIdentities {
            signal(SIGTERM, ifStill: identity)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + gracePeriod
        while children.contains(where: { $0.process.isRunning }),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        for identity in processIdentities {
            signal(SIGKILL, ifStill: identity)
        }
    }

    /// A captured PID alone is unsafe across a TERM grace period because the
    /// kernel may reuse it for an unrelated process before escalation.
    private static func processIdentity(for identifier: pid_t) -> ProcessIdentity? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            identifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize)
        guard actualSize == expectedSize else { return nil }
        return ProcessIdentity(
            identifier: identifier,
            startToken: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
        #else
        guard let stat = try? String(
            contentsOfFile: "/proc/\(identifier)/stat",
            encoding: .utf8),
              let commandEnd = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: commandEnd)...].split {
            $0 == " " || $0 == "\n"
        }
        // The suffix begins at proc(5) field 3; starttime is field 22.
        guard fields.indices.contains(19) else { return nil }
        return ProcessIdentity(
            identifier: identifier,
            startToken: String(fields[19]))
        #endif
    }

    private static func signal(_ signal: Int32, ifStill identity: ProcessIdentity) {
        guard processIdentity(for: identity.identifier) == identity else { return }
        kill(identity.identifier, signal)
    }

    #if canImport(Darwin)
    private static func descendantProcessIdentifiers(
        of parent: pid_t
    ) -> [pid_t] {
        // Despite the buffer being byte-sized, this API's successful return is
        // a PID count. Dividing it by MemoryLayout<pid_t>.stride drops children.
        let estimatedCount = proc_listchildpids(parent, nil, 0)
        guard estimatedCount > 0 else { return [] }
        var children = [pid_t](
            repeating: 0,
            count: Int(estimatedCount) + 8)
        let returnedCount = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedCount > 0 else { return [] }
        return children.prefix(min(children.count, Int(returnedCount)))
            .filter { $0 > 0 }.flatMap {
                descendantProcessIdentifiers(of: $0) + [$0]
            }
    }
    #else
    private static func descendantProcessIdentifiers(
        of parent: pid_t
    ) -> [pid_t] {
        guard let children = try? String(
            contentsOfFile: "/proc/\(parent)/task/\(parent)/children",
            encoding: .utf8) else { return [] }
        return children.split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
            .flatMap { descendantProcessIdentifiers(of: $0) + [$0] }
    }
    #endif
}

private struct ChildProcess {
    let shardIndex: Int
    let process: Process
    let stdout: FileHandle
    let stderr: FileHandle
    let stdoutURL: URL
    let stderrURL: URL
    let startedAt: TimeInterval
}

private struct ProcessIdentity: Equatable {
    let identifier: pid_t
    let startToken: String
}
