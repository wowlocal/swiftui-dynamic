import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite("Parallel Foundation gateways")
struct ParallelFoundationGatewayTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test
    func detachedFileManagerMoveUsesAWorkerAndPropagatesFailure()
        async throws
    {
        let fixture = repositoryRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-file-manager-move.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedFileManagerMoveProbe()\n"
        let expected = "worker|source:false|destination:true|copy:true|missing:error"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == expected)
        #expect(parallelValue.stringValue == expected)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 4)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 3)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func detachedFileManagerRemoveUsesAWorkerAndPropagatesFailure()
        async throws
    {
        let fixture = repositoryRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-file-manager-remove.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedFileManagerRemoveProbe()\n"
        let expected = "url:true|path:true|missing:error"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == expected)
        #expect(parallelValue.stringValue == expected)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 3)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 2)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func detachedFileManagerExistsUsesAWorker() async throws {
        let fixture = repositoryRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-file-manager-exists.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedFileManagerExistsProbe()\n"
        let expected = "present:true|missing:false"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == expected)
        #expect(parallelValue.stringValue == expected)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 2)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 2)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func sourceShadowedFileManagerStaysOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct FileManager {
            static let `default` = FileManager()

            func moveItem(at: String, to: String) -> String {
                "source:\\(at):\\(to)"
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.moveItem(at: "a", to: "b")
            }.value
        }

        await probe()
        """)

        #expect(value.stringValue == "source:a:b")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func sourceShadowedFileManagerRemoveStaysOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct FileManager {
            static let `default` = FileManager()

            func removeItem(at: String) -> String {
                "removed:" + at
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.removeItem(at: "source")
            }.value
        }

        await probe()
        """)

        #expect(value.stringValue == "removed:source")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func sourceShadowedFileManagerExistsStaysOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct FileManager {
            static let `default` = FileManager()

            func fileExists(atPath: String) -> String {
                "source:" + atPath
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.fileExists(atPath: "path")
            }.value
        }

        await probe()
        """)

        #expect(value.stringValue == "source:path")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func fileManagerExistsInoutOverloadStaysOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        func probe() async -> String {
            let path = FileManager.default.temporaryDirectory.path
            let exists = await Task.detached {
                FileManager.default.fileExists(
                    atPath: path, isDirectory: nil)
            }.value
            return exists ? "exists" : "missing"
        }

        await probe()
        """)

        #expect(value.stringValue == "exists")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func fileManagerSandboxIsOwnedByItsRegistry() throws {
        let firstRegistry = ViewRegistry()
        let secondRegistry = ViewRegistry()
        let firstRoot = firstRegistry.fileManagerBox.sandboxRoot
        let secondRoot = secondRegistry.fileManagerBox.sandboxRoot
        let sentinel = firstRoot.appendingPathComponent("sentinel.txt")

        #expect(firstRoot != secondRoot)
        try FileManager.default.createDirectory(
            at: firstRoot,
            withIntermediateDirectories: true)
        try Data("alive".utf8).write(to: sentinel)

        secondRegistry.storeBlob(.native("other-registry"), at: sentinel.path)
        HeadlessVerifier.resetBridgeEnvironment()

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "alive")
        #expect(firstRegistry.fileManagerBox.blobStore[sentinel.path] == nil)
        #expect(secondRegistry.fileManagerBox.blobStore[sentinel.path]?.stringValue
            == "other-registry")
    }
}
