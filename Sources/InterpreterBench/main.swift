import Foundation
import SwiftInterpreter
import SwiftUIBridge

private struct Options {
    var project: String?
    var warmup = 2
    var samples = 7
    var minimumSampleSeconds = 0.10
    var json = false

    init(arguments: ArraySlice<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--project":
                guard let value = iterator.next() else { throw UsageError("--project requires a path") }
                project = value
            case "--warmup":
                guard let value = iterator.next(), let parsed = Int(value), parsed >= 0 else {
                    throw UsageError("--warmup requires a non-negative integer")
                }
                warmup = parsed
            case "--samples":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw UsageError("--samples requires a positive integer")
                }
                samples = parsed
            case "--minimum-sample-seconds":
                guard let value = iterator.next(), let parsed = Double(value), parsed > 0 else {
                    throw UsageError("--minimum-sample-seconds requires a positive number")
                }
                minimumSampleSeconds = parsed
            case "--json":
                json = true
            case "--help", "-h":
                throw UsageError(Self.usage, exitCode: 0)
            default:
                throw UsageError("unknown argument: \(argument)")
            }
        }
    }

    static let usage = """
    Usage: swift run -c release InterpreterBench [options]
      --project PATH                  Swift project to benchmark (default: Examples/ExpenseTracker)
      --warmup N                      Warm-up operations per workload (default: 2)
      --samples N                     Measured samples per workload (default: 7)
      --minimum-sample-seconds N      Minimum duration of a sample batch (default: 0.10)
      --json                          Emit machine-readable JSON
    """
}

private struct UsageError: Error, CustomStringConvertible {
    let description: String
    let exitCode: Int32

    init(_ description: String, exitCode: Int32 = 2) {
        self.description = description
        self.exitCode = exitCode
    }
}

private struct Metric: Codable {
    let name: String
    let medianMilliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double
    let operationsPerSample: Int

    enum CodingKeys: String, CodingKey {
        case name
        case medianMilliseconds = "median_ms"
        case minimumMilliseconds = "minimum_ms"
        case maximumMilliseconds = "maximum_ms"
        case operationsPerSample = "operations_per_sample"
    }
}

private struct Report: Codable {
    let project: String
    let swiftFileCount: Int
    let sourceBytes: Int
    let warmupOperations: Int
    let samples: Int
    let metrics: [Metric]

    enum CodingKeys: String, CodingKey {
        case project
        case swiftFileCount = "swift_file_count"
        case sourceBytes = "source_bytes"
        case warmupOperations = "warmup_operations"
        case samples
        case metrics
    }
}

private let initializerDispatchSource = """
struct BenchValue {
    var value: Int

    init(text: String, flag: Bool = false, count: Int = 0) { value = count }
    init(flag: Bool, text: String = "", count: Int = 0) { value = count }
    init(_ value: Int, text: String = "", flag: Bool = false) { self.value = value }
    init(left: Int, right: Int, scale: Int = 1) { value = (left + right) * scale }
    init(count: Int, flag: Bool = false, text: String = "") { value = count }
    init(value: Int, scale: Int = 1, enabled: Bool = true) { self.value = value * scale }
}

var checksum = 0
for index in 0..<200 {
    checksum += BenchValue(value: index).value
    checksum += BenchValue(left: index, right: 1).value
    checksum += BenchValue(count: index).value
}
checksum
"""

@main
private struct InterpreterBench {
    @MainActor
    static func main() {
        do {
            let options = try Options(arguments: CommandLine.arguments.dropFirst())
            let project = try resolveProject(options.project)
            let files = ProjectMaterial.swiftFiles(under: project)
            guard !files.isEmpty else { throw UsageError("no Swift files found under \(project)") }
            let source = ProjectMaterial.mergedSource(files: files)
            let sourceBytes = source.lengthOfBytes(using: .utf8)

            var checksum = 0
            let workloads: [(String, () throws -> Int)] = [
                ("parse", {
                    let interpreter = Interpreter()
                    let tree = try interpreter.parse(source: source)
                    return tree.statements.count
                }),
                ("run", {
                    let interpreter = Interpreter(registry: TraceRegistry())
                    let value = try interpreter.run(source: source)
                    return value.stringified.count
                }),
                ("render", {
                    let report = try HeadlessVerifier.verify(source: source, interactions: false)
                    return report.nodeCount
                }),
                ("verify_actions", {
                    let report = try HeadlessVerifier.verify(source: source, interactions: true)
                    return report.nodeCount &+ report.actionsInvoked
                }),
                ("initializer_dispatch", {
                    let interpreter = Interpreter()
                    let value = try interpreter.run(source: initializerDispatchSource)
                    return value.intValue ?? value.stringified.count
                }),
            ]

            var metrics: [Metric] = []
            for (name, operation) in workloads {
                let metric = try measure(
                    name: name,
                    warmup: options.warmup,
                    samples: options.samples,
                    minimumSampleSeconds: options.minimumSampleSeconds,
                    checksum: &checksum,
                    operation: operation)
                metrics.append(metric)
                if !options.json { printMetric(metric) }
            }

            let report = Report(
                project: project,
                swiftFileCount: files.count,
                sourceBytes: sourceBytes,
                warmupOperations: options.warmup,
                samples: options.samples,
                metrics: metrics)
            if options.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            } else {
                print("checksum: \(checksum)")
            }
        } catch let error as UsageError {
            let suffix = error.description == Options.usage ? "" : "\n\n\(Options.usage)"
            FileHandle.standardError.write(Data("\(error.description)\(suffix)\n".utf8))
            Foundation.exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("InterpreterBench failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    @MainActor
    private static func measure(
        name: String,
        warmup: Int,
        samples: Int,
        minimumSampleSeconds: Double,
        checksum: inout Int,
        operation: () throws -> Int
    ) throws -> Metric {
        for _ in 0..<warmup { checksum &+= try operation() }

        let estimateStart = DispatchTime.now().uptimeNanoseconds
        checksum &+= try operation()
        let estimateSeconds = max(
            Double(DispatchTime.now().uptimeNanoseconds - estimateStart) / 1_000_000_000,
            0.000_001)
        let operationsPerSample = max(1, Int(ceil(minimumSampleSeconds / estimateSeconds)))

        var milliseconds: [Double] = []
        milliseconds.reserveCapacity(samples)
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<operationsPerSample { checksum &+= try operation() }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            milliseconds.append(Double(elapsed) / 1_000_000 / Double(operationsPerSample))
        }
        milliseconds.sort()
        return Metric(
            name: name,
            medianMilliseconds: milliseconds[milliseconds.count / 2],
            minimumMilliseconds: milliseconds[0],
            maximumMilliseconds: milliseconds[milliseconds.count - 1],
            operationsPerSample: operationsPerSample)
    }

    private static func printMetric(_ metric: Metric) {
        let name = metric.name.padding(toLength: 22, withPad: " ", startingAt: 0)
        print(String(
            format: "%@ %9.3f ms  (%9.3f...%9.3f, %d ops/sample)",
            name,
            metric.medianMilliseconds,
            metric.minimumMilliseconds,
            metric.maximumMilliseconds,
            metric.operationsPerSample))
    }

    private static func resolveProject(_ requested: String?) throws -> String {
        let fileManager = FileManager.default
        if let requested {
            return URL(fileURLWithPath: requested, relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath))
                .standardizedFileURL.path
        }
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Examples/ExpenseTracker").path
            if fileManager.fileExists(atPath: candidate) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw UsageError("could not locate Examples/ExpenseTracker; pass --project PATH")
    }
}
