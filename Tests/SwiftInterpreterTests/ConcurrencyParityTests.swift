import Darwin
import Foundation
import Testing
@testable import SwiftInterpreter

private enum ParityMode: String, Decodable {
    case runtime
    case diagnostic
}

private enum ParityAssertionKind: String, Decodable {
    case exact
    case allowedSet = "allowed-set"
    case partialOrder = "partial-order"
    case predicate
    case diagnostic
    case stress
}

private struct ConcurrencyParityCase: Decodable {
    let id: String
    let fixture: String
    let mode: ParityMode
    let assertion: ParityAssertionKind
    let repetitions: Int
    let timeoutSeconds: TimeInterval
    let interpreterEntry: String?
    let interpreterProjection: String?
    let allowedOutputs: [String]?
    let requiredEvents: [String]?
    let precedes: [[String]]?
    let predicate: String?
    let diagnosticContains: [String]?
    let diagnosticLine: Int?
    let nativeFact: String
    let notes: String
}

private struct ParityProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

private struct ConcurrencyToolchainFingerprint: CustomStringConvertible {
    let swiftcPath: String
    let swiftVersion: String
    let sdkPath: String
    let sdkVersion: String

    var description: String {
        "swiftc=\(swiftcPath) | \(swiftVersion) | sdk=\(sdkVersion) \(sdkPath)"
    }
}

/// Test host carrier: the callback payload is consumed only by its MainActor
/// method. `Task.detached` crosses the native task-local boundary while all
/// interpreter access remains actor-confined.
private struct DetachedHostCallback: @unchecked Sendable {
    let context: EvalContext
    let closure: ClosureValue

    @MainActor
    func call() async throws -> RuntimeValue {
        try await context.callClosureAsync(closure, arguments: [])
    }
}

private enum ConcurrencyParityHarness {
    static let packageRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static let parityRoot = packageRoot
        .appendingPathComponent("Tests/ConcurrencyParity", isDirectory: true)

    static func loadCases() throws -> [ConcurrencyParityCase] {
        let url = parityRoot.appendingPathComponent(
            "Manifests/parity-cases.json")
        return try JSONDecoder().decode(
            [ConcurrencyParityCase].self, from: Data(contentsOf: url))
    }

    static func fingerprint() throws -> ConcurrencyToolchainFingerprint {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let swiftc = try successful(
            run(xcrun, ["--find", "swiftc"], timeout: 10),
            operation: "locate swiftc").standardOutput.trimmed
        let version = try successful(
            run(URL(fileURLWithPath: swiftc), ["--version"], timeout: 10),
            operation: "read swiftc version").standardOutput.trimmed
        let sdkPath = try successful(
            run(xcrun, ["--show-sdk-path", "--sdk", "macosx"], timeout: 10),
            operation: "locate macOS SDK").standardOutput.trimmed
        let sdkVersion = try successful(
            run(xcrun, ["--show-sdk-version", "--sdk", "macosx"], timeout: 10),
            operation: "read macOS SDK version").standardOutput.trimmed
        return ConcurrencyToolchainFingerprint(
            swiftcPath: swiftc,
            swiftVersion: version.replacingOccurrences(of: "\n", with: " | "),
            sdkPath: sdkPath,
            sdkVersion: sdkVersion)
    }

    static func nativeOutputs(
        for parityCase: ConcurrencyParityCase
    ) throws -> [String] {
        let directory = try makeTemporaryDirectory(for: parityCase.id)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("probe")
        let fixture = parityRoot.appendingPathComponent(parityCase.fixture)
        let wrapper = parityRoot.appendingPathComponent("Support/NativeMain.swift")
        let compile = run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            [
                "swiftc",
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-parse-as-library",
                fixture.path,
                wrapper.path,
                "-o", binary.path,
            ],
            timeout: 30)
        _ = try successful(compile, operation: "compile \(parityCase.id)")

        var outputs: [String] = []
        for _ in 0..<max(1, parityCase.repetitions) {
            let execution = run(
                binary, [], timeout: parityCase.timeoutSeconds)
            let successfulExecution = try successful(
                execution, operation: "run \(parityCase.id)")
            outputs.append(successfulExecution.standardOutput.trimmed)
        }
        return outputs
    }

    static func diagnostic(
        for parityCase: ConcurrencyParityCase
    ) -> ParityProcessResult {
        let fixture = parityRoot.appendingPathComponent(parityCase.fixture)
        return run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            [
                "swiftc",
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-typecheck",
                fixture.path,
            ],
            timeout: parityCase.timeoutSeconds)
    }

    @MainActor
    static func interpretedOutputs(
        for parityCase: ConcurrencyParityCase
    ) async throws -> [String] {
        var outputs: [String] = []
        for _ in 0..<max(1, parityCase.repetitions) {
            outputs.append(try await interpretedOutput(for: parityCase))
        }
        return outputs
    }

    @MainActor
    private static func interpretedOutput(
        for parityCase: ConcurrencyParityCase
    ) async throws -> String {
        guard let entry = parityCase.interpreterEntry,
              let projection = parityCase.interpreterProjection else {
            throw RuntimeError(message:
                "runtime parity case '\(parityCase.id)' needs an interpreter entry and projection")
        }
        let fixture = parityRoot.appendingPathComponent(parityCase.fixture)
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\n" + entry + "\n"
        let interpreter = Interpreter()
        var waitStarted = false
        var expectedDetachedContextID: UInt64?
        interpreter.globals.define("parityYield", .hostFunction(HostFunction(
            name: "parityYield",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))
        interpreter.globals.define("parityWaitForever", .hostFunction(HostFunction(
            name: "parityWaitForever",
            asyncInvoke: { _, _ in
                waitStarted = true
                try await Task.sleep(for: .seconds(30))
                return .void
            }
        )))
        interpreter.globals.define("parityAwaitWaitStarted", .hostFunction(HostFunction(
            name: "parityAwaitWaitStarted",
            asyncInvoke: { _, _ in
                while !waitStarted { await Task.yield() }
                return .void
            }
        )))
        interpreter.globals.define("parityDetachedInheritance", .hostFunction(HostFunction(
            name: "parityDetachedInheritance",
            asyncInvoke: { _, _ in
                let inherited = await Task.detached { @MainActor in
                    EvaluationTaskContext.current != nil
                }.value
                return .native(inherited ? "inherited" : "lost")
            }
        )))
        interpreter.globals.define("parityDetachedReentry", .hostFunction(HostFunction(
            name: "parityDetachedReentry",
            asyncInvoke: { arguments, context in
                guard let closure = arguments.firstUnlabeledClosure,
                      let bound = context as? TaskBoundEvalContext else {
                    throw RuntimeError(message:
                        "detached re-entry requires a task-bound closure context")
                }
                expectedDetachedContextID = bound.evaluationTaskContextID
                let callback = DetachedHostCallback(
                    context: context, closure: closure)
                return try await Task.detached {
                    try await callback.call()
                }.value
            }
        )))
        interpreter.globals.define("parityCheckContext", .hostFunction(HostFunction(
            name: "parityCheckContext",
            asyncInvoke: { _, context in
                guard let bound = context as? TaskBoundEvalContext else {
                    return .native("wrong")
                }
                return .native(
                    bound.evaluationTaskContextID == expectedDetachedContextID
                        ? "preserved" : "wrong")
            }
        )))
        let value = try await interpreter.runAsync(source: source)

        if projection == "string" {
            guard let string = value.stringValue else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' returned \(value.stringified), expected String")
            }
            return string
        }
        if projection.hasPrefix("instance-string-array:") {
            let property = String(projection.dropFirst(
                "instance-string-array:".count))
            guard case .instance(let instance) = value,
                  let elements = instance.box(for: property)?.value.arrayValue else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' did not return an instance [String] property '\(property)'")
            }
            return elements.compactMap(\.stringValue).joined(separator: ",")
        }
        if projection.hasPrefix("instance-task-state-and-string-array:") {
            let fields = projection.dropFirst(
                "instance-task-state-and-string-array:".count)
                .split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2,
                  case .instance(let instance) = value,
                  let taskValue = instance.box(for: fields[0])?.value
                    .unwrappedOptionalOrSelf,
                  case .host(let payload) = taskValue,
                  let handle = payload as? RuntimeTaskHandle,
                  let elements = instance.box(for: fields[1])?.value.arrayValue else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' did not return the expected task and [String] properties")
            }
            let events = elements.compactMap(\.stringValue).joined(separator: ",")
            return handle.state.rawValue + "," + events
        }
        throw RuntimeError(message:
            "unknown interpreter projection '\(projection)' for '\(parityCase.id)'")
    }

    static func violations(
        assertion: ParityAssertionKind,
        native: [String],
        interpreted: [String],
        allowedOutputs: [String]? = nil,
        requiredEvents: [String]? = nil,
        precedes: [[String]]? = nil,
        predicate: String? = nil
    ) -> [String] {
        switch assertion {
        case .exact:
            guard let first = native.first else { return ["exact assertion needs native output"] }
            guard !interpreted.isEmpty else { return ["exact assertion needs interpreter output"] }
            var problems: [String] = []
            if native.contains(where: { $0 != first }) {
                problems.append("native exact output was unstable: \(native)")
            }
            for output in interpreted where output != first {
                problems.append("native '\(first)' != interpreted '\(output)'")
            }
            return problems

        case .allowedSet:
            guard !interpreted.isEmpty else { return ["allowed-set assertion needs interpreter output"] }
            let allowed = Set(allowedOutputs ?? native)
            guard !allowed.isEmpty else { return ["allowed set is empty"] }
            return (native + interpreted).compactMap { output in
                allowed.contains(output) ? nil : "output '\(output)' is not in \(allowed.sorted())"
            }

        case .partialOrder:
            guard !interpreted.isEmpty else { return ["partial-order assertion needs interpreter output"] }
            return (native + interpreted).flatMap {
                traceViolations(
                    $0, requiredEvents: requiredEvents ?? [],
                    precedes: precedes ?? [])
            }

        case .predicate:
            guard !interpreted.isEmpty else { return ["predicate assertion needs interpreter output"] }
            switch predicate {
            case "nonempty":
                return (native + interpreted).compactMap {
                    $0.isEmpty ? "output is empty" : nil
                }
            case "same-event-multiset":
                guard let first = native.first else {
                    return ["same-event-multiset needs native output"]
                }
                let expected = first.split(separator: ",").sorted()
                return (Array(native.dropFirst()) + interpreted).compactMap { output in
                    output.split(separator: ",").sorted() == expected
                        ? nil : "event multiset differs in '\(output)'"
                }
            default:
                return ["unknown predicate '\(predicate ?? "nil")'"]
            }

        case .stress:
            guard !native.isEmpty else { return ["stress assertion needs native completion"] }
            guard !interpreted.isEmpty else { return ["stress assertion needs interpreter completion"] }
            return []
        case .diagnostic:
            return ["diagnostics are validated from compiler status/stderr"]
        }
    }

    private static func traceViolations(
        _ output: String,
        requiredEvents: [String],
        precedes: [[String]]
    ) -> [String] {
        let events = output.split(separator: ",").map(String.init)
        var problems: [String] = []
        for event in requiredEvents {
            let count = events.count(where: { $0 == event })
            if count != 1 {
                problems.append("trace '\(output)' contains '\(event)' \(count) times")
            }
        }
        for pair in precedes {
            guard pair.count == 2 else {
                problems.append("invalid precedence pair \(pair)")
                continue
            }
            guard let lhs = events.firstIndex(of: pair[0]),
                  let rhs = events.firstIndex(of: pair[1]) else { continue }
            if lhs >= rhs {
                problems.append("trace '\(output)' violates \(pair[0]) < \(pair[1])")
            }
        }
        return problems
    }

    private static func successful(
        _ result: ParityProcessResult, operation: String
    ) throws -> ParityProcessResult {
        if result.timedOut {
            throw RuntimeError(message: "\(operation) timed out")
        }
        if result.status != 0 {
            throw RuntimeError(message:
                "\(operation) failed (\(result.status)):\n\(result.standardError)")
        }
        return result
    }

    private static func makeTemporaryDirectory(for id: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-concurrency-\(id)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> ParityProcessResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-process-\(UUID().uuidString)",
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
              let stderr = try? FileHandle(forWritingTo: stderrURL) else {
            return ParityProcessResult(
                status: -1, standardOutput: "", standardError: "could not create output files",
                timedOut: false)
        }
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = packageRoot
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ParityProcessResult(
                status: -1, standardOutput: "",
                standardError: String(describing: error), timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()

        let standardOutput = (try? String(
            contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let standardError = (try? String(
            contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return ParityProcessResult(
            status: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError,
            timedOut: timedOut)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite("Concurrency native parity", .serialized)
struct ConcurrencyParityTests {
    @Test func toolchainFingerprintIsComplete() throws {
        let fingerprint = try ConcurrencyParityHarness.fingerprint()
        #expect(!fingerprint.swiftcPath.isEmpty)
        #expect(fingerprint.swiftVersion.contains("Swift version 6"))
        #expect(!fingerprint.sdkPath.isEmpty)
        #expect(!fingerprint.sdkVersion.isEmpty)
    }

    @Test func runtimeFixturesMatchNativeGuarantees() async throws {
        let cases = try ConcurrencyParityHarness.loadCases()
            .filter { $0.mode == .runtime }
        #expect(!cases.isEmpty)

        for parityCase in cases {
            let native = try ConcurrencyParityHarness.nativeOutputs(
                for: parityCase)
            let interpreted = try await ConcurrencyParityHarness
                .interpretedOutputs(for: parityCase)
            let problems = ConcurrencyParityHarness.violations(
                assertion: parityCase.assertion,
                native: native,
                interpreted: interpreted,
                allowedOutputs: parityCase.allowedOutputs,
                requiredEvents: parityCase.requiredEvents,
                precedes: parityCase.precedes,
                predicate: parityCase.predicate)
            if !problems.isEmpty {
                Issue.record("\(parityCase.id): \(problems.joined(separator: "; "))")
            }
        }
    }

    @Test func diagnosticFixturesMatchRealCompiler() throws {
        let cases = try ConcurrencyParityHarness.loadCases()
            .filter { $0.mode == .diagnostic }
        #expect(!cases.isEmpty)

        for parityCase in cases {
            let result = ConcurrencyParityHarness.diagnostic(for: parityCase)
            #expect(!result.timedOut, "\(parityCase.id) timed out")
            #expect(result.status != 0, "\(parityCase.id) unexpectedly typechecked")
            for fragment in parityCase.diagnosticContains ?? [] {
                #expect(result.standardError.contains(fragment),
                    "\(parityCase.id) did not contain '\(fragment)': \(result.standardError)")
            }
            if let line = parityCase.diagnosticLine {
                #expect(result.standardError.contains(":\(line):"),
                    "\(parityCase.id) did not diagnose line \(line): \(result.standardError)")
            }
        }
    }

    @Test func assertionEngineDetectsDivergenceAndSupportsNonExactRules() {
        let exactMismatch = ConcurrencyParityHarness.violations(
            assertion: .exact,
            native: ["native"],
            interpreted: ["interpreter"])
        #expect(!exactMismatch.isEmpty)

        let allowed = ConcurrencyParityHarness.violations(
            assertion: .allowedSet,
            native: ["a", "b"],
            interpreted: ["b"],
            allowedOutputs: ["a", "b"])
        #expect(allowed.isEmpty)

        let predicate = ConcurrencyParityHarness.violations(
            assertion: .predicate,
            native: ["a,b", "b,a"],
            interpreted: ["b,a"],
            predicate: "same-event-multiset")
        #expect(predicate.isEmpty)

        let emptyStress = ConcurrencyParityHarness.violations(
            assertion: .stress,
            native: [],
            interpreted: [])
        #expect(!emptyStress.isEmpty)
    }

    @Test func harnessRejectsIntentionallyBadInterpreterParity() throws {
        let parityCase = try #require(
            ConcurrencyParityHarness.loadCases().first {
                $0.id == "async-function-exact"
            })
        let native = try ConcurrencyParityHarness.nativeOutputs(for: parityCase)
        let problems = ConcurrencyParityHarness.violations(
            assertion: parityCase.assertion,
            native: native,
            interpreted: ["deliberately-wrong"])
        #expect(!problems.isEmpty)
    }

    @Test func sourceTasksOwnDistinctEvaluatorContexts() async throws {
        let fixture = ConcurrencyParityHarness.parityRoot
            .appendingPathComponent(
                "Fixtures/task-owned-evaluator-context.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskContextProbe()\n"
        let interpreter = Interpreter()
        var contextIDs: [UInt64] = []
        var retainedContexts: [UInt64: EvaluationTaskContext] = [:]
        interpreter.globals.define("parityYield", .hostFunction(HostFunction(
            name: "parityYield",
            asyncInvoke: { arguments, context in
                await Task.yield()
                let contextID: UInt64
                if let bound = context as? TaskBoundEvalContext {
                    contextID = bound.evaluationTaskContextID
                    retainedContexts[contextID] = bound.evaluationContext
                } else if let interpreter = context as? Interpreter {
                    contextID = interpreter.currentEvaluationTaskContextID
                } else {
                    throw RuntimeError(message: "unknown EvalContext implementation")
                }
                contextIDs.append(contextID)
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let value = try await interpreter.runAsync(source: source)
        guard case .instance(let recorder) = value,
              let values = recorder.box(for: "values")?.value.arrayValue else {
            Issue.record("task-context fixture did not return its recorder")
            return
        }
        #expect(values.count == 100)
        #expect(Set(contextIDs).count == 100)
        #expect(retainedContexts.count == 100)
        #expect(retainedContexts.values.allSatisfy { $0.isDynamicallyEmpty })
    }

}
