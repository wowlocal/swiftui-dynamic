import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Runtime isolation boundary")
struct RuntimeIsolationBoundaryTests {
    @Test nonisolated func immutableDescriptorsCrossDetachedBoundary() async {
        let observation = await Task.detached {
            let session = RuntimeSessionID(rawValue: 7)
            let task = RuntimeTaskID(rawValue: 11)
            let deadline = RuntimeInstant.zero.advanced(by: .milliseconds(3))
            return "\(session)|\(task)|\(deadline.nanoseconds)"
        }.value

        #expect(observation == "session-7|task-11|3000000")
    }

    @Test func publicModulePinsMutableRuntimeToMainActor() throws {
        let neutral = try typecheck("ExecutorNeutralDescriptors.swift")
        #expect(neutral.status == 0, Comment(rawValue: neutral.output))

        let confined = try typecheck("MutableRuntimeOffActor.swift")
        #expect(confined.status != 0)
        let isolationErrors = confined.output.split(separator: "\n").filter {
            $0.contains(": error: call to main actor-isolated")
        }
        #expect(isolationErrors.count == 3, Comment(rawValue: confined.output))
        #expect(confined.output.contains(
            "initializer 'init(registry:buildConfiguration:)'"))
        #expect(confined.output.contains("static method 'native'"))
        #expect(confined.output.contains("RuntimeHeap"))
        #expect(confined.output.contains("Interpreter"))
        #expect(confined.output.contains("RuntimeValue"))
    }

    @Test func nativeDetachedWorkRequiresAnActorSnapshot() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: executable) }

        let compiled = try runSwiftCompiler(
            fixtureName: "NativeDetachedSnapshot.swift",
            arguments: ["-parse-as-library", "-o", executable.path])
        #expect(compiled.status == 0, Comment(rawValue: compiled.output))
        let executed = try run(executable.path, arguments: [])
        #expect(executed.status == 0, Comment(rawValue: executed.output))
        #expect(executed.output.trimmingCharacters(in: .whitespacesAndNewlines)
            == "2,3,5,10|10")

        let rejected = try runSwiftCompiler(
            fixtureName: "NativeDetachedHeapCapture.swift",
            arguments: ["-typecheck"])
        #expect(rejected.status != 0)
        #expect(rejected.output.contains(
            "main actor-isolated property 'values'"),
            Comment(rawValue: rejected.output))
        #expect(rejected.output.contains("outside of the actor"),
            Comment(rawValue: rejected.output))
    }

    @Test func nativeDetachedTasksCanOverlapPhysically() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: executable) }

        let compiled = try runSwiftCompiler(
            fixtureName: "NativeDetachedOverlap.swift",
            arguments: ["-parse-as-library", "-o", executable.path])
        #expect(compiled.status == 0, Comment(rawValue: compiled.output))
        let executed = try run(executable.path, arguments: [])
        #expect(executed.status == 0, Comment(rawValue: executed.output))
        #expect(executed.output.trimmingCharacters(in: .whitespacesAndNewlines)
            == "overlap:2")
    }

    private func typecheck(_ fixtureName: String) throws -> TypecheckResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/RuntimeIsolation/\(fixtureName)")
        let modules = root.appendingPathComponent(".build/debug/Modules")
        let cShims = root.appendingPathComponent(
            ".build/checkouts/swift-syntax/Sources/_SwiftSyntaxCShims/include")

        try #require(FileManager.default.fileExists(atPath: fixture.path))
        try #require(FileManager.default.fileExists(atPath: modules.path))
        try #require(FileManager.default.fileExists(atPath: cShims.path))

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc",
            "-swift-version", "6",
            "-strict-concurrency=complete",
            "-warnings-as-errors",
            "-typecheck",
            "-I", modules.path,
            "-Xcc", "-I",
            "-Xcc", cShims.path,
            fixture.path,
        ]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return TypecheckResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }

    private func runSwiftCompiler(
        fixtureName: String, arguments: [String]
    ) throws -> TypecheckResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/RuntimeIsolation/\(fixtureName)")
        return try run(
            "/usr/bin/xcrun",
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-warnings-as-errors",
            ] + arguments + [fixture.path],
            currentDirectory: root)
    }

    private func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> TypecheckResult {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return TypecheckResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }
}

private struct TypecheckResult {
    let status: Int32
    let output: String
}
