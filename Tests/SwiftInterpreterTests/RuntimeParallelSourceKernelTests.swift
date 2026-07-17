import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Parallel source snapshot kernel")
struct RuntimeParallelSourceKernelTests {
    @Test func parallelismConfigurationRejectsInvalidBounds() {
        #expect(throws:
            RuntimeParallelismConfigurationError
                .invalidMaximumParallelism(0)) {
            try RuntimeParallelismConfiguration(maximumParallelism: 0)
        }
        #expect(throws:
            RuntimeParallelismConfigurationError
                .invalidMaximumParallelism(-1)) {
            try RuntimeParallelismConfiguration(maximumParallelism: -1)
        }
    }

    @Test func literalDetachedTasksUseTheOptInPhysicalMode() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func probe() async -> String {
            let text = Task.detached { "atlas" }
            let number = Task.detached { 42 }
            let textValue = await text.value
            let numberValue = await number.value
            return textValue + ":\\(numberValue)"
        }
        await probe()
        """)

        #expect(value.stringValue == "atlas:42")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
    }

    @Test func cooperativeModeKeepsTheSameSourceOnTheEvaluator() async throws {
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: """
        let task = Task.detached { "cooperative" }
        await task.value
        """)

        #expect(value.stringValue == "cooperative")
        #expect(interpreter.executionMode == .cooperative)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
    }

    @Test func immutableStringCountCaptureUsesThePhysicalExpressionKernel()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func probe() async -> String {
            let atlas = "atlas"
            let foodtruck = "foodtruck"
            let atlasCount = Task.detached { atlas.count }
            let foodtruckCount = Task.detached { foodtruck.count }
            let first = await atlasCount.value
            let second = await foodtruckCount.value
            return "\\(first):\\(second)"
        }
        await probe()
        """)

        #expect(value.stringValue == "5:9")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
    }

    @Test func mutableAndGlobalStringCapturesStayOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let globalText = "global"

        @MainActor
        func probe() async -> String {
            var mutableText = "atlas"
            let mutableCount = Task.detached { mutableText.count }
            let globalCount = Task.detached { globalText.count }
            let first = await mutableCount.value
            let second = await globalCount.value
            return "\\(first):\\(second)"
        }
        await probe()
        """)

        #expect(value.stringValue == "5:6")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
    }

    @Test func unsupportedClosureFallsBackWithoutPartialWorkerEvaluation()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let literal = Task.detached { "physical" }
        let expression = Task.detached { 40 + 2 }
        let literalValue = await literal.value
        let expressionValue = await expression.value
        literalValue + ":\\(expressionValue)"
        """)

        #expect(value.stringValue == "physical:42")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
    }

    @Test func authoredClosureSignaturesStayOnTheCooperativeEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let task = Task.detached { () -> String in "typed" }
        await task.value
        """)

        #expect(value.stringValue == "typed")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
    }

    @Test func immediateDetachedKeepsItsDistinctLaunchPath() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let task = Task.immediateDetached(executorPreference: nil) {
            "immediate"
        }
        await task.value
        """)

        #expect(value.stringValue == "immediate")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
    }

    @Test func cooperativeAndParallelModesRemainEquivalent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-literal-detached.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelLiteralDetachedProbe()\n"
        let configuration = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)

        for _ in 0..<20 {
            let cooperative = Interpreter()
            let parallel = Interpreter(
                executionMode: .parallel(configuration))
            let cooperativeValue = try await cooperative.runAsync(
                source: source)
            let parallelValue = try await parallel.runAsync(source: source)

            #expect(cooperativeValue.stringValue == "atlas:42")
            #expect(parallelValue.stringValue
                == cooperativeValue.stringValue)
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 2)
            #expect(cooperative.concurrencyRuntime.activeRecordCount == 0)
            #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
        }
    }

    @Test func capturedStringCountModesRemainEquivalent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-captured-string-count.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelCapturedStringCountProbe()\n"
        let configuration = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)

        for _ in 0..<20 {
            let cooperative = Interpreter()
            let parallel = Interpreter(
                executionMode: .parallel(configuration))
            let cooperativeValue = try await cooperative.runAsync(
                source: source)
            let parallelValue = try await parallel.runAsync(source: source)

            #expect(cooperativeValue.stringValue == "5:9")
            #expect(parallelValue.stringValue
                == cooperativeValue.stringValue)
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 2)
            #expect(cooperative.concurrencyRuntime.activeRecordCount == 0)
            #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
        }
    }
}
