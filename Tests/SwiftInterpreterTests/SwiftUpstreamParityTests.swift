import Darwin
import CryptoKit
import Foundation
import Testing
@testable import SwiftInterpreter

private struct SwiftUpstreamManifest: Decodable {
    struct Case: Decodable, Sendable {
        let id: String
        let fixture: String
        let upstreamPath: String
        let sha256: String?
        let assertion: Assertion?
        let compilerArguments: [String]?
        let diagnosticContains: [String]?
        let diagnosticLines: [Int]?
        let interpreterDiagnosticContains: [String]?
        let timeoutSeconds: TimeInterval?
    }

    struct SupportFile: Decodable {
        let id: String
        let moduleName: String
        let fixture: String
        let upstreamPath: String
        let sha256: String
        let purpose: String
    }

    enum Assertion: String, Decodable, Sendable {
        case exact
        case fileCheck = "file-check"
        case fileCheckUnordered = "file-check-unordered"
        case diagnostic
        case interpreterDiagnostic = "interpreter-diagnostic"
    }

    let repository: String
    let revision: String
    let commit: String
    let supportFiles: [SupportFile]
    let cases: [Case]
}

private struct SwiftUpstreamInventory: Decodable {
    struct Summary: Decodable {
        let total: Int
        let direct: Int
        let diagnostic: Int
        let needsAdapter: Int
        let unsupported: Int
    }

    struct Entry: Decodable {
        let upstreamPath: String
        let classification: String
        let reason: String
        let selectedCaseID: String?
    }

    let repository: String
    let revision: String
    let commit: String
    let scope: String
    let classificationVersion: Int
    let summary: Summary
    let tests: [Entry]
}

private struct SwiftUpstreamProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

private struct SwiftUpstreamParityError: Error, CustomStringConvertible {
    let description: String
}

/// Differential runner for unmodified executable tests imported from the
/// official Swift repository. The native compiler remains the semantic
/// oracle; the same source is then executed by the tree-walking interpreter.
private enum SwiftUpstreamParityHarness {
    nonisolated static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    nonisolated static let corpusRoot = packageRoot
        .appendingPathComponent("Tests/SwiftUpstream", isDirectory: true)

    static func loadManifest() throws -> SwiftUpstreamManifest {
        let url = corpusRoot.appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(
            SwiftUpstreamManifest.self, from: Data(contentsOf: url))
    }

    static func loadInventory() throws -> SwiftUpstreamInventory {
        let url = corpusRoot.appendingPathComponent("inventory.json")
        return try JSONDecoder().decode(
            SwiftUpstreamInventory.self, from: Data(contentsOf: url))
    }

    nonisolated static func source(
        for parityCase: SwiftUpstreamManifest.Case
    ) throws -> String {
        try verifiedSource(
            fixture: parityCase.fixture,
            expectedSHA256: parityCase.sha256,
            identity: parityCase.id)
    }

    static func supportSource(
        for support: SwiftUpstreamManifest.SupportFile
    ) throws -> String {
        try verifiedSource(
            fixture: support.fixture,
            expectedSHA256: support.sha256,
            identity: support.id)
    }

    nonisolated private static func verifiedSource(
        fixture: String,
        expectedSHA256: String?,
        identity: String
    ) throws -> String {
        let fixture = corpusRoot.appendingPathComponent(fixture)
        let data = try Data(contentsOf: fixture)
        if let expected = expectedSHA256 {
            let actual = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            guard actual == expected else {
                throw SwiftUpstreamParityError(description:
                    "\(identity) fixture SHA-256 is \(actual), expected \(expected)")
            }
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw SwiftUpstreamParityError(description:
                "\(identity) fixture is not UTF-8")
        }
        return source
    }

    nonisolated static func nativeOutput(
        for parityCase: SwiftUpstreamManifest.Case
    ) throws -> String {
        let fixture = corpusRoot.appendingPathComponent(parityCase.fixture)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-upstream-\(parityCase.id)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let moduleCache = temporaryDirectory
            .appendingPathComponent("ModuleCache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: moduleCache, withIntermediateDirectories: true)
        let executable = temporaryDirectory.appendingPathComponent("fixture")
        let compilationArguments = (parityCase.compilerArguments ?? []) + [
            "-module-cache-path", moduleCache.path,
            fixture.path,
            "-o", executable.path,
        ]
        let compilation = run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            ["swiftc"] + compilationArguments,
            timeout: 30)
        guard !compilation.timedOut else {
            throw SwiftUpstreamParityError(
                description: "native compilation timed out")
        }
        guard compilation.status == 0 else {
            throw SwiftUpstreamParityError(description:
                "native compilation failed (\(compilation.status)):\n"
                    + compilation.standardError)
        }

        let execution = run(
            executable, [], timeout: parityCase.timeoutSeconds ?? 5)
        guard !execution.timedOut else {
            throw SwiftUpstreamParityError(
                description: "native execution timed out")
        }
        guard execution.status == 0 else {
            throw SwiftUpstreamParityError(description:
                "native execution failed (\(execution.status)):\n"
                    + execution.standardError)
        }
        return execution.standardOutput
    }

    @MainActor
    static func interpretedOutput(
        for parityCase: SwiftUpstreamManifest.Case
    ) async throws -> String {
        var source = try source(for: parityCase)
        if let mainType = mainTypeName(in: source) {
            // Native swiftc invokes @main after loading the declarations. The
            // tree-walking interpreter receives the same fixture plus this
            // generic harness entry; no upstream source is rewritten and no
            // fixture/type name is encoded in runtime behavior.
            source += "\nawait \(mainType).main()\n"
        }
        var output = ""
        let interpreter = Interpreter()

        // Capture the interpreter's general print gateway instead of
        // rewriting upstream source or teaching the runtime fixture names.
        // separator:/terminator: are handled with their standard defaults so
        // the adapter remains useful for any executable Swift fixture.
        interpreter.globals.define(
            "print",
            .hostFunction(HostFunction(name: "print") { arguments, _ in
                let values = arguments.arguments
                    .filter { $0.label == nil && !$0.isTrailing }
                    .map { $0.value.stringValue ?? $0.value.stringified }
                let separator = arguments.labeled("separator")?.stringValue
                    ?? " "
                let terminator = arguments.labeled("terminator")?.stringValue
                    ?? "\n"
                output += values.joined(separator: separator) + terminator
                return .void
            }))
        _ = try await interpreter.runAsync(source: source)
        return output
    }

    static func mainTypeName(in source: String) -> String? {
        let expression = try? NSRegularExpression(pattern:
            #"(?m)^[\t ]*@main[\t ]*(?:\n[\t ]*)?(?:(?:public|internal|private|fileprivate|final)[\t ]+)*(?:struct|class|enum)[\t ]+([A-Za-z_][A-Za-z0-9_]*)"#)
        let sourceRange = NSRange(location: 0, length: source.utf16.count)
        guard let match = expression?.firstMatch(
            in: source, options: [], range: sourceRange),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return String(source[range])
    }

    nonisolated private static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> SwiftUpstreamProcessResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-upstream-process-\(UUID().uuidString)",
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(
            atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(
            atPath: stderrURL.path, contents: nil)
        guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
              let stderr = try? FileHandle(forWritingTo: stderrURL) else {
            return SwiftUpstreamProcessResult(
                status: -1, standardOutput: "",
                standardError: "could not create output files",
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
            return SwiftUpstreamProcessResult(
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

        return SwiftUpstreamProcessResult(
            status: process.terminationStatus,
            standardOutput: (try? String(
                contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            standardError: (try? String(
                contentsOf: stderrURL, encoding: .utf8)) ?? "",
            timedOut: timedOut)
    }
}

private nonisolated func listSwiftUpstreamExecutableCaseIDs() -> [String] {
    let manifest = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/SwiftUpstream/manifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          let cases = root["cases"] as? [[String: Any]] else {
        return []
    }
    return cases.compactMap { entry in
        if let assertion = entry["assertion"] as? String,
           assertion == "diagnostic"
                || assertion == "interpreter-diagnostic" {
            return nil
        }
        return entry["id"] as? String
    }
}

private nonisolated let swiftUpstreamExecutableCaseIDs =
    listSwiftUpstreamExecutableCaseIDs()

@Suite("Official Swift interpreter-test parity")
struct SwiftUpstreamParityTests {
    @Test func importedManifestPinsEverySelectedFixture() throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        #expect(manifest.repository == "https://github.com/swiftlang/swift.git")
        #expect(manifest.revision == "swift-6.3.3-RELEASE")
        #expect(manifest.commit == "064859e41d68596f486c5d724401cb370f260409")
        #expect(manifest.cases.count == 27)
        #expect(Set(manifest.cases.map(\.id)).count == manifest.cases.count)
        #expect(Set(manifest.cases.map(\.upstreamPath)).count
            == manifest.cases.count)
        #expect(manifest.cases.allSatisfy { $0.sha256?.count == 64 })
        #expect(manifest.supportFiles.count == 4)
        #expect(Set(manifest.supportFiles.map(\.id)).count
            == manifest.supportFiles.count)
        #expect(Set(manifest.supportFiles.map(\.upstreamPath)).count
            == manifest.supportFiles.count)
        #expect(manifest.supportFiles.allSatisfy {
            $0.sha256.count == 64 && !$0.purpose.isEmpty
        })

        let executableCases = manifest.cases.filter {
            $0.assertion != .diagnostic
                && $0.assertion != .interpreterDiagnostic
        }
        #expect(executableCases.count == 23)
        #expect(manifest.cases.count {
            $0.assertion == .interpreterDiagnostic
        } == 1)
        #expect(swiftUpstreamExecutableCaseIDs
            == executableCases.map(\.id))
    }

    /// Each unchanged upstream executable is one independently schedulable
    /// test case. Native compilation can therefore use Swift Testing's worker
    /// pool instead of serializing the entire allowlist inside one test body.
    @Test(arguments: swiftUpstreamExecutableCaseIDs)
    nonisolated func importedExecutableTestsMatchNativeSwift(
        caseID: String
    ) async throws {
        let parityCase = try await MainActor.run {
            let manifest = try SwiftUpstreamParityHarness.loadManifest()
            return try #require(manifest.cases.first {
                $0.id == caseID && $0.assertion != .diagnostic
            })
        }
        let source = try SwiftUpstreamParityHarness.source(for: parityCase)
        let native = try SwiftUpstreamParityHarness.nativeOutput(
            for: parityCase)
        let interpreted = try await SwiftUpstreamParityHarness
            .interpretedOutput(for: parityCase)
        try await MainActor.run {
            switch parityCase.assertion ?? .exact {
            case .exact:
                if interpreted != native {
                    let details = "\(parityCase.id) "
                        + "(\(parityCase.upstreamPath)) differed: "
                        + "native=\(String(reflecting: native)), "
                        + "interpreted=\(String(reflecting: interpreted))"
                    Issue.record(Comment(rawValue: details))
                }
            case .fileCheck:
                for (runtime, output) in [
                    ("native", native),
                    ("interpreter", interpreted),
                ] {
                    let problems = try SwiftUpstreamFileCheck.violations(
                        source: source, output: output)
                    for problem in problems {
                        Issue.record(Comment(rawValue:
                            "\(parityCase.id) "
                                + "(\(parityCase.upstreamPath)) "
                                + "\(runtime): \(problem); output="
                                + String(reflecting: output)))
                    }
                }
            case .fileCheckUnordered:
                for (runtime, output) in [
                    ("native", native),
                    ("interpreter", interpreted),
                ] {
                    let problems = try SwiftUpstreamFileCheck
                        .unorderedViolations(source: source, output: output)
                    for problem in problems {
                        Issue.record(Comment(rawValue:
                            "\(parityCase.id) "
                                + "(\(parityCase.upstreamPath)) "
                                + "\(runtime): \(problem); output="
                                + String(reflecting: output)))
                    }
                }
            case .diagnostic:
                Issue.record(
                    "diagnostic case entered the executable runner")
            case .interpreterDiagnostic:
                Issue.record(
                    "interpreter-diagnostic case entered the parity runner")
            }
        }
    }

    @Test
    func mainActorDeinitializerFailsClosedAgainstPinnedOracle() async throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        let parityCase = try #require(manifest.cases.first {
            $0.id == "concurrency-main-actor-deinitializer"
                && $0.assertion == .interpreterDiagnostic
        })
        let source = try SwiftUpstreamParityHarness.source(for: parityCase)
        let native = try SwiftUpstreamParityHarness.nativeOutput(
            for: parityCase)
        #expect(try SwiftUpstreamFileCheck.violations(
            source: source, output: native).isEmpty,
            Comment(rawValue: native))

        do {
            let output = try await SwiftUpstreamParityHarness
                .interpretedOutput(for: parityCase)
            Issue.record(Comment(rawValue:
                "isolated deinitializer unexpectedly ran: "
                    + String(reflecting: output)))
        } catch let error as RuntimeError {
            for fragment in parityCase.interpreterDiagnosticContains ?? [] {
                #expect(error.message.contains(fragment),
                    Comment(rawValue: error.description))
            }
        }
    }

    @Test func importedDiagnosticsMatchProductionCompilerPreflight() throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        let diagnosticCases = manifest.cases.filter {
            $0.assertion == .diagnostic
        }
        #expect(diagnosticCases.count == 3)
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            gatewayManifestSHA256:
                SwiftCompilerPreflight.emptyGatewayManifestSHA256)

        for parityCase in diagnosticCases {
            let source = try SwiftUpstreamParityHarness.source(for: parityCase)
            let fileName = URL(fileURLWithPath: parityCase.fixture)
                .lastPathComponent
            let result = try preflight.preflight(
                source: source,
                fileName: fileName)
            #expect(!result.succeeded,
                "\(parityCase.id) unexpectedly passed native preflight")
            for fragment in parityCase.diagnosticContains ?? [] {
                #expect(result.diagnostics.contains {
                    $0.severity == .error
                        && $0.file == fileName
                        && $0.message.contains(fragment)
                }, "\(parityCase.id) did not contain '\(fragment)'")
            }
            for line in parityCase.diagnosticLines ?? [] {
                #expect(result.diagnostics.contains {
                    $0.severity == .error
                        && $0.file == fileName
                        && $0.line == line
                },
                    "\(parityCase.id) did not diagnose line \(line)")
            }
        }
    }

    @Test func importedSupportModulePreservesMainActorIsolation() throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        let support = try #require(manifest.supportFiles.first {
            $0.id == "global-actor-isolated-function-module"
        })
        let module = CompilerPreflightHostModule(
            moduleName: support.moduleName,
            source: try SwiftUpstreamParityHarness.supportSource(for: support))
        #expect(module.sourceSHA256 == support.sha256)
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: module)
        let client = try String(
            contentsOf: SwiftUpstreamParityHarness.packageRoot
                .appendingPathComponent(
                    "Tests/SwiftUpstream/Clients/host-module-mainactor-diagnostic.swift"),
            encoding: .utf8)
        let result = try preflight.preflight(
            source: client,
            fileName: "host-module-mainactor-diagnostic.swift")

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.file == "host-module-mainactor-diagnostic.swift"
                && $0.line == 4
                && $0.message.contains("main actor-isolated global function")
                && $0.message.contains("nonisolated context")
        })
    }

    @Test
    func importedSupportModulePreservesStaticPropertyMainActorIsolation()
        throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        let support = try #require(manifest.supportFiles.first {
            $0.id == "global-actor-isolated-static-property-module"
        })
        let module = CompilerPreflightHostModule(
            moduleName: support.moduleName,
            source: try SwiftUpstreamParityHarness.supportSource(for: support),
            compilerArguments: [
                "-swift-version", "5",
                "-strict-concurrency=minimal",
            ])
        #expect(module.sourceSHA256 == support.sha256)
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: module)
        #expect(preflight.configuration.additionalCompilerArguments.isEmpty)
        let clientName =
            "host-module-mainactor-static-property-diagnostic.swift"
        let client = try String(
            contentsOf: SwiftUpstreamParityHarness.packageRoot
                .appendingPathComponent("Tests/SwiftUpstream/Clients/\(clientName)"),
            encoding: .utf8)
        let result = try preflight.preflight(
            source: client,
            fileName: clientName)

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.file == clientName
                && $0.line == 4
                && $0.message.contains(
                    "main actor-isolated static property 'actorInteger'")
                && $0.message.contains("nonisolated context")
        }, Comment(rawValue: result.standardError))
    }

    @Test func importedSupportModulePreservesMainActorTypeIsolation() throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        let support = try #require(manifest.supportFiles.first {
            $0.id == "global-actor-isolated-type-module"
        })
        let module = CompilerPreflightHostModule(
            moduleName: support.moduleName,
            source: try SwiftUpstreamParityHarness.supportSource(for: support))
        #expect(module.sourceSHA256 == support.sha256)
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            hostModule: module)
        let clientName = "host-module-mainactor-type-diagnostic.swift"
        let client = try String(
            contentsOf: SwiftUpstreamParityHarness.packageRoot
                .appendingPathComponent("Tests/SwiftUpstream/Clients/\(clientName)"),
            encoding: .utf8)
        let result = try preflight.preflight(
            source: client,
            fileName: clientName)

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.file == clientName
                && $0.line == 8
                && $0.message.contains(
                    "call to main actor-isolated instance method 'isolatedMember()'")
                && $0.message.contains("nonisolated context")
        }, Comment(rawValue: result.standardError))
    }

    @Test func importedTaskGroupsPreserveMainActorIsolation() throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        let support = try #require(manifest.supportFiles.first {
            $0.id == "task-group-mainactor-isolation-oracle"
        })
        let source = try SwiftUpstreamParityHarness.supportSource(for: support)
        let preflight = try SwiftCompilerPreflight.activeMacOS(
            gatewayManifestSHA256:
                SwiftCompilerPreflight.emptyGatewayManifestSHA256)
        let fileName = "async_task_groups_and_actors.swift"
        let result = try preflight.preflight(
            source: source,
            fileName: fileName)

        #expect(support.upstreamPath
            == "test/Concurrency/async_task_groups_and_actors.swift")
        #expect(result.succeeded, Comment(rawValue: result.standardError))
        #expect(!result.diagnostics.contains { $0.severity == .error })
    }

    @Test func concurrencyRuntimeInventoryClassifiesEveryPinnedSource() throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        let inventory = try SwiftUpstreamParityHarness.loadInventory()
        #expect(inventory.repository == manifest.repository)
        #expect(inventory.revision == manifest.revision)
        #expect(inventory.commit == manifest.commit)
        #expect(inventory.scope == "test/Concurrency/Runtime")
        #expect(inventory.classificationVersion == 1)
        #expect(inventory.tests.count == 134)
        #expect(inventory.summary.total == inventory.tests.count)
        #expect(inventory.summary.total == inventory.summary.direct
            + inventory.summary.diagnostic
            + inventory.summary.needsAdapter
            + inventory.summary.unsupported)
        #expect(Set(inventory.tests.map(\.upstreamPath)).count
            == inventory.tests.count)
        #expect(inventory.tests.allSatisfy { !$0.reason.isEmpty })
        #expect(inventory.tests.allSatisfy {
            ["direct", "diagnostic", "needs-adapter", "unsupported"]
                .contains($0.classification)
        })

        let concurrencyCases = manifest.cases.filter {
            $0.upstreamPath.hasPrefix("test/Concurrency/Runtime/")
        }
        let selectedByPath = Dictionary(uniqueKeysWithValues:
            concurrencyCases.map { ($0.upstreamPath, $0.id) })
        let directByPath = Dictionary(uniqueKeysWithValues:
            inventory.tests.compactMap { entry -> (String, String)? in
                guard entry.classification == "direct",
                      let selectedCaseID = entry.selectedCaseID else {
                    return nil
                }
                return (entry.upstreamPath, selectedCaseID)
            })
        #expect(directByPath == selectedByPath)
        #expect(inventory.summary.direct == concurrencyCases.count)
        #expect(concurrencyCases.allSatisfy { parityCase in
            switch parityCase.assertion {
            case .fileCheck, .fileCheckUnordered:
                parityCase.compilerArguments == [
                    "-swift-version", "6",
                    "-strict-concurrency=complete",
                    "-parse-as-library",
                ]
            case .interpreterDiagnostic:
                parityCase.compilerArguments == [
                    "-swift-version", "6",
                    "-strict-concurrency=complete",
                    "-warnings-as-errors",
                    "-default-isolation", "MainActor",
                ] && parityCase.interpreterDiagnosticContains?.isEmpty == false
            case .exact, .diagnostic, nil:
                false
            }
        })
    }

    @Test func asyncMainDetectionIsGeneric() {
        #expect(SwiftUpstreamParityHarness.mainTypeName(in: """
            @available(macOS 15, *)
            @main
            public struct ProbeRunner {
                static func main() async {}
            }
            """) == "ProbeRunner")
        #expect(SwiftUpstreamParityHarness.mainTypeName(
            in: "// @main struct CommentOnly {}") == nil)
    }
}
