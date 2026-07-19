import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// The declarative file-service table (FileServiceOperations) drives BOTH
/// execution faces of every forwarded FileManager member. These tests pin:
/// exact source-visible behavior in cooperative AND parallel modes (the two
/// faces can never disagree — they share one prepared kernel), physical
/// submission/execution receipts, argument-shape behavior, source-shadow
/// rejection, and the route-metadata mirror.
///
/// Serialized: the probes perform real file operations against the shared
/// per-process sandbox; overlap belongs to the corpus/gate stages, not here.
@Suite("Parallel file service gateways", .serialized)
struct ParallelFileServiceGatewayTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runFixture(
        named fixtureName: String,
        entry: String,
        expected: String,
        parallelSubmissions: Int,
        parallelExecutions: Int
    ) async throws {
        let fixture = repositoryRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/\(fixtureName).swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\n\(entry)\n"
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
            .totalPhysicalHostOperationSubmissions == parallelSubmissions)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == parallelExecutions)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func detachedFileManagerMoveUsesAWorkerAndPropagatesFailure()
        async throws
    {
        try await runFixture(
            named: "parallel-detached-file-manager-move",
            entry: "await parallelDetachedFileManagerMoveProbe()",
            expected:
                "worker|source:false|destination:true|copy:true|missing:error",
            parallelSubmissions: 4,
            parallelExecutions: 3)
    }

    @Test
    func detachedFileManagerRemoveUsesAWorkerAndPropagatesFailure()
        async throws
    {
        try await runFixture(
            named: "parallel-detached-file-manager-remove",
            entry: "await parallelDetachedFileManagerRemoveProbe()",
            expected: "url:true|path:true|missing:error",
            parallelSubmissions: 3,
            parallelExecutions: 2)
    }

    @Test
    func detachedFileManagerExistsUsesAWorker() async throws {
        try await runFixture(
            named: "parallel-detached-file-manager-exists",
            entry: "await parallelDetachedFileManagerExistsProbe()",
            expected: "present:true|missing:false",
            parallelSubmissions: 2,
            parallelExecutions: 2)
    }

    @Test
    func detachedFileManagerCreateDirectoryUsesAWorker() async throws {
        try await runFixture(
            named: "parallel-detached-file-manager-create-directory",
            entry: "await parallelDetachedFileManagerCreateDirectoryProbe()",
            expected: "url:true|path:true",
            parallelSubmissions: 2,
            parallelExecutions: 2)
    }

    @Test
    func detachedFileManagerListUsesAWorker() async throws {
        try await runFixture(
            named: "parallel-detached-file-manager-list",
            entry: "await parallelDetachedFileManagerListProbe()",
            expected: "alpha|beta|gamma",
            parallelSubmissions: 1,
            parallelExecutions: 1)
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
    func sourceShadowedFileManagerCreateDirectoryStaysConfined()
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

            func createDirectory(
                at: String, withIntermediateDirectories: Bool
            ) -> String {
                "source:" + at
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.createDirectory(
                    at: "path", withIntermediateDirectories: true)
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
    func createDirectoryArgumentShapesShareTheRowSemantics()
        async throws
    {
        // One table row serves every accepted argument shape, so the
        // uncited spellings (withIntermediateDirectories: false, explicit
        // attributes) cross like the cited ones and produce the identical
        // sandbox-lenient effect on both faces.
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        func probe() async -> String {
            let root = FileManager.default.temporaryDirectory
            let first = root.appendingPathComponent("without-intermediates")
            let second = root.appendingPathComponent("with-attributes")
            try? await Task.detached {
                try FileManager.default.createDirectory(
                    at: first, withIntermediateDirectories: false)
            }.value
            try? await Task.detached {
                try FileManager.default.createDirectory(
                    at: second,
                    withIntermediateDirectories: true,
                    attributes: nil)
            }.value
            let created = FileManager.default.fileExists(atPath: first.path)
                && FileManager.default.fileExists(atPath: second.path)
            return created ? "created" : "missing"
        }

        await probe()
        """)

        #expect(value.stringValue == "created")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func fileManagerExistsIsDirectoryShapeSharesTheRowSemantics()
        async throws
    {
        // The confined face has always answered the isDirectory: spelling
        // by reading atPath and ignoring the out-parameter; the worker face
        // shares that row, so the shape crosses with the same answer.
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
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func routeMetadataMirrorsTheOperationTable() async {
        let registry = ViewRegistry()

        await MainActor.run {
            #expect(FileServiceRouting.workerRoutedMembers
                == Set(FileServiceOperations.all.map(\.member)))
        }
        #expect(registry.hostMemberHasWorkerOperation(
            "removeItem", onStaticMember: "default", ofType: "FileManager"))
        #expect(registry.hostMemberHasWorkerOperation(
            "contentsOfDirectory",
            onStaticMember: "default",
            ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "enumerator", onStaticMember: "default", ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "temporaryDirectory",
            onStaticMember: "default",
            ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "removeItem", onStaticMember: "shared", ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "removeItem", onStaticMember: "default", ofType: "Bundle"))
    }

    @Test
    func fileManagerSandboxIsOwnedByItsRegistry() throws {
        // The parallel-worker sandbox race: a process-global root let any
        // concurrent verification reset delete or redirect an in-flight
        // interpreter's files. Each registry owns its container now, and
        // the bridge-environment reset must not touch it.
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
