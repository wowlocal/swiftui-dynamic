import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Generated Task concurrency surface", .serialized)
struct GeneratedTaskSurfaceTests {
    @Test
    func activeInterfaceMetadataDrivesTaskStaticDispatch() throws {
        #expect(Set(GeneratedConcurrencySurface.taskStaticDispatch.keys) == [
            "checkCancellation", "currentPriority", "detached",
            "isCancelled", "sleep", "yield",
        ])
        #expect(GeneratedConcurrencySurface.knownTaskStaticMembers.contains(
            "basePriority"))
        let sleep = try #require(
            GeneratedConcurrencySurface.taskStaticMemberDeclarations["sleep"])
        #expect(sleep.contains {
            $0.isAsync && $0.throwsKind == .nonThrowing
                && $0.parameters.first?.label == nil
        })
        #expect(sleep.contains {
            $0.isAsync && $0.throwsKind == .throwing
                && $0.parameters.contains { $0.label == "nanoseconds" }
        })
        let detached = try #require(
            GeneratedConcurrencySurface.taskStaticMemberDeclarations["detached"])
        #expect(detached.contains { declaration in
            declaration.parameters.contains {
                $0.name == "operation" && $0.hasIsolatedFunctionType
            }
        })

        #expect(Set(GeneratedConcurrencySurface.taskInstanceDispatch.keys) == [
            "cancel", "isCancelled", "result", "value",
        ])
        #expect(GeneratedConcurrencySurface.knownTaskInstanceMembers.contains(
            "get"))
        let get = try #require(
            GeneratedConcurrencySurface.taskInstanceMemberDeclarations["get"])
        #expect(get.count == 2)
        #expect(get.contains { $0.isAsync && $0.isThrowing })
        #expect(get.contains { $0.isAsync && !$0.isThrowing })
        let getResult = try #require(
            GeneratedConcurrencySurface.taskInstanceMemberDeclarations["getResult"])
        #expect(getResult.count == 1)
        #expect(getResult.allSatisfy { $0.isAsync && !$0.isThrowing })
        let value = try #require(
            GeneratedConcurrencySurface.taskInstanceMemberDeclarations["value"])
        #expect(value.contains { $0.isAsync && $0.isThrowing })
        #expect(value.contains { $0.isAsync && !$0.isThrowing })
        let result = try #require(
            GeneratedConcurrencySurface.taskInstanceMemberDeclarations["result"])
        #expect(result.contains { $0.isAsync && !$0.isThrowing })
    }

    @Test
    @MainActor
    func generatedButUnsupportedTaskStaticMemberIsExplicit() {
        do {
            _ = try Interpreter().run(source: "Task.basePriority")
            Issue.record("unsupported generated Task member was absorbed")
        } catch {
            #expect(String(describing: error).contains(
                "Task.basePriority is declared by the active "
                    + "_Concurrency.swiftinterface but is not supported yet"))
        }
    }

    @Test
    @MainActor
    func unsupportedGeneratedDetachedOverloadIsNotSilentlyDowngraded()
        async {
        do {
            _ = try await Interpreter().runAsync(source: """
            let task = Task.detached(executorPreference: nil) { 1 }
            await task.value
            """)
            Issue.record("executor-preference overload was silently ignored")
        } catch {
            #expect(String(describing: error).contains(
                "Task.detached(executorPreference:) is declared by the active "
                    + "_Concurrency.swiftinterface but is not supported yet"))
        }
    }

    @Test
    @MainActor
    func generatedButUnsupportedTaskInstanceMembersAreExplicit() async {
        for member in [
            "escalatePriority", "get", "getResult", "hash", "hashValue",
        ] {
            do {
                _ = try await Interpreter().runAsync(source: """
                let task = Task { 1 }
                task.\(member)
                """)
                Issue.record("unsupported generated Task.\(member) was absorbed")
            } catch {
                #expect(String(describing: error).contains(
                    "Task.\(member) is declared by the active "
                        + "_Concurrency.swiftinterface but is not supported yet"))
            }
        }
    }

    @Test
    @MainActor
    func sameSourceStaticTaskOperationsMatchNativeSwift() async throws {
        let fixture = Self.packageRoot.appendingPathComponent(
            "Tests/NativeProbes/Concurrency/"
                + "task-static-generated-surface.swift")
        let nativeMain = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Support/NativeMain.swift")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "generated-task-surface-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("probe")

        let compile = try Self.run(
            "/usr/bin/xcrun",
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-parse-as-library",
                fixture.path,
                nativeMain.path,
                "-o", binary.path,
            ],
            timeoutSeconds: 30)
        #expect(compile.status == 0, "\(compile.standardError)")
        let native = try Self.run(
            binary.path, arguments: [], timeoutSeconds: 5)
        #expect(native.status == 0, "\(native.standardError)")
        let nativeOutput = native.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
        #expect(nativeOutput == "active:detached")

        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\ntry await taskStaticGeneratedSurfaceProbe()\n"
        let interpreted = try await Interpreter().runAsync(source: source)
        #expect(interpreted.stringValue == nativeOutput)
    }

    private struct ProcessOutput {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw RuntimeError(message:
                "process exceeded its \(timeoutSeconds)-second deadline")
        }
        process.waitUntilExit()
        return ProcessOutput(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self),
            standardError: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self))
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
