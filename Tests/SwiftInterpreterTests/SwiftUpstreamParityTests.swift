import Darwin
import Foundation
import Testing
@testable import SwiftInterpreter

private struct SwiftUpstreamManifest: Decodable {
    struct Case: Decodable {
        let id: String
        let fixture: String
        let upstreamPath: String
    }

    let repository: String
    let revision: String
    let commit: String
    let cases: [Case]
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
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let corpusRoot = packageRoot
        .appendingPathComponent("Tests/SwiftUpstream", isDirectory: true)

    static func loadManifest() throws -> SwiftUpstreamManifest {
        let url = corpusRoot.appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(
            SwiftUpstreamManifest.self, from: Data(contentsOf: url))
    }

    static func nativeOutput(
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
        let compilation = run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            [
                "swiftc",
                "-module-cache-path", moduleCache.path,
                fixture.path,
                "-o", executable.path,
            ],
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

        let execution = run(executable, [], timeout: 5)
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
    ) throws -> String {
        let fixture = corpusRoot.appendingPathComponent(parityCase.fixture)
        let source = try String(contentsOf: fixture, encoding: .utf8)
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
        _ = try interpreter.run(source: source)
        return output
    }

    private static func run(
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

@Suite("Official Swift interpreter-test parity", .serialized)
struct SwiftUpstreamParityTests {
    @Test func importedExecutableTestsMatchNativeSwift() throws {
        let manifest = try SwiftUpstreamParityHarness.loadManifest()
        #expect(manifest.repository == "https://github.com/swiftlang/swift.git")
        #expect(manifest.revision == "swift-6.2.3-RELEASE")
        #expect(manifest.commit == "484e622d1c0afcae5b12a31c090a74ad0901e44f")
        #expect(manifest.cases.count == 10)
        #expect(Set(manifest.cases.map(\.id)).count == manifest.cases.count)

        for parityCase in manifest.cases {
            do {
                let native = try SwiftUpstreamParityHarness.nativeOutput(
                    for: parityCase)
                let interpreted = try SwiftUpstreamParityHarness
                    .interpretedOutput(for: parityCase)
                if interpreted != native {
                    let details = "\(parityCase.id) "
                        + "(\(parityCase.upstreamPath)) differed: "
                        + "native=\(String(reflecting: native)), "
                        + "interpreted=\(String(reflecting: interpreted))"
                    Issue.record(Comment(rawValue: details))
                }
            } catch {
                Issue.record(
                    "\(parityCase.id) (\(parityCase.upstreamPath)): \(error)")
            }
        }
    }
}
