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
}
