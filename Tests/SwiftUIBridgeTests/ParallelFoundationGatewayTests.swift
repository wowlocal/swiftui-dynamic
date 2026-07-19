import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite("Parallel Foundation gateways", .serialized)
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
}
