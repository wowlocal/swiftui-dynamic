import Darwin
import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Compiler-backed concurrency preflight", .serialized)
struct CompilerPreflightTests {
    @Test
    func requiredModeRejectsNativeDiagnosticBeforeInterpreterMutation()
        async throws {
        let engine = try Self.activePreflight()
        let interpreter = Interpreter(compilerPreflight: engine)
        let source = try Self.fixture("actor-isolation-diagnostic.swift")

        do {
            _ = try await interpreter.runAsync(source: source)
            Issue.record("actor-isolation violation unexpectedly executed")
        } catch let rejection as CompilerPreflightRejection {
            #expect(!rejection.result.succeeded)
            #expect(rejection.result.diagnostics.contains {
                $0.severity == .error
                    && $0.file == "input.swift"
                    && $0.line == 6
                    && $0.message.contains("actor-isolated property")
                    && $0.message.contains("nonisolated context")
            })
        }

        #expect(interpreter.lastCompilerPreflightResult?.succeeded == false)
        #expect(interpreter.globals.lookup("Counter") == nil)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func diagnosticsOnlyModeRetainsErrorsAndAllowsEditorRecovery() throws {
        let engine = try Self.activePreflight()
        let interpreter = Interpreter(
            compilerPreflight: engine,
            compilerPreflightMode: .diagnosticsOnly)
        let source = try Self.fixture("actor-isolation-diagnostic.swift")

        _ = try interpreter.run(source: source)

        #expect(interpreter.lastCompilerPreflightResult?.succeeded == false)
        let retainedDiagnostic = interpreter.lastCompilerPreflightResult?
            .diagnostics.contains {
            $0.severity == .error && $0.line == 6
        }
        #expect(retainedDiagnostic == true)
        #expect(interpreter.globals.lookup("Counter") != nil)
    }

    @Test
    func legalProgramExecutesAndRepeatedPreflightUsesCache() throws {
        let engine = try Self.activePreflight()
        let source = """
        func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
        add(20, 22)
        """

        let first = try engine.preflight(source: source)
        let second = try engine.preflight(source: source)
        #expect(first.succeeded)
        #expect(!first.wasCached)
        #expect(second.succeeded)
        #expect(second.wasCached)
        #expect(first.cacheKey == second.cacheKey)

        let interpreter = Interpreter(compilerPreflight: engine)
        let value = try interpreter.run(source: source)
        #expect(value.intValue == 42)
        #expect(interpreter.lastCompilerPreflightResult?.wasCached == true)
    }

    @Test
    func cacheKeyInvalidatesOnSourceToolchainSDKTargetAndManifest() throws {
        var invocationCount = 0
        let cache = CompilerPreflightCache(capacity: 16)
        func engine(
            compilerVersion: String = "Swift A",
            sdkVersion: String = "SDK A",
            target: String = "arm64-apple-macosx15.0",
            manifest: String = String(repeating: "a", count: 64)
        ) -> SwiftCompilerPreflight {
            let configuration = CompilerPreflightConfiguration(
                swiftCompilerPath: "/toolchain/swiftc",
                compilerVersion: compilerVersion,
                sdkPath: "/SDK",
                sdkVersion: sdkVersion,
                targetTriple: target,
                deploymentTarget: target.split(separator: "x").last
                    .map(String.init) ?? "15.0",
                gatewayManifestSHA256: manifest)
            return SwiftCompilerPreflight(
                configuration: configuration,
                cache: cache,
                executor: { _, _, fileName in
                    invocationCount += 1
                    return CompilerPreflightInvocationOutput(
                        exitStatus: 0,
                        standardOutput: "",
                        standardError: "",
                        sourcePath: fileName)
                })
        }

        let baseline = engine()
        let first = try baseline.preflight(source: "let value = 1")
        let repeated = try baseline.preflight(source: "let value = 1")
        #expect(invocationCount == 1)
        #expect(!first.wasCached)
        #expect(repeated.wasCached)

        let sourceChanged = try baseline.preflight(source: "let value = 2")
        let compilerChanged = try engine(compilerVersion: "Swift B")
            .preflight(source: "let value = 1")
        let sdkChanged = try engine(sdkVersion: "SDK B")
            .preflight(source: "let value = 1")
        let targetChanged = try engine(target: "x86_64-apple-macosx15.0")
            .preflight(source: "let value = 1")
        let manifestChanged = try engine(
            manifest: String(repeating: "b", count: 64)
        ).preflight(source: "let value = 1")

        #expect(invocationCount == 6)
        let keys = [
            first, sourceChanged, compilerChanged, sdkChanged, targetChanged,
            manifestChanged,
        ].map(\.cacheKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test
    func timeoutTerminatesCompilerDescendantProcessTree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "compiler-preflight-timeout-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-swiftc")
        let descendantPIDFile = directory.appendingPathComponent(
            "descendant-pid")
        try """
        #!/bin/sh
        trap '' TERM
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        echo $! > "\(descendantPIDFile.path)"
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        let configuration = CompilerPreflightConfiguration(
            swiftCompilerPath: script.path,
            compilerVersion: "fake compiler",
            sdkPath: "/fake-sdk",
            sdkVersion: "fake sdk",
            targetTriple: "arm64-apple-macosx15.0",
            deploymentTarget: "15.0",
            gatewayManifestSHA256: String(repeating: "a", count: 64),
            timeoutSeconds: 0.2)
        let engine = SwiftCompilerPreflight(configuration: configuration)

        do {
            _ = try engine.preflight(source: "let value = 1")
            Issue.record("stuck compiler unexpectedly completed")
        } catch CompilerPreflightError.timedOut(let timeout) {
            #expect(timeout == 0.2)
        }

        let rawPID = try String(
            contentsOf: descendantPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let descendantPID = try #require(pid_t(rawPID))
        for _ in 0..<100 where Darwin.kill(descendantPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(Darwin.kill(descendantPID, 0) == -1 && errno == ESRCH)
    }

    private static func activePreflight() throws -> SwiftCompilerPreflight {
        try SwiftCompilerPreflight.activeMacOS(
            gatewayManifestSHA256:
                SwiftCompilerPreflight.emptyGatewayManifestSHA256)
    }

    private static func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Tests/ConcurrencyParity/Fixtures")
                .appendingPathComponent(name),
            encoding: .utf8)
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
