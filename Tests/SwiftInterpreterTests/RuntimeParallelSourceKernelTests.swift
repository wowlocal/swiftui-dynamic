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
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
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
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
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

    @Test func immutableStringArrayCountReductionUsesPhysicalExpressionKernel()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func probe() async -> String {
            let atlas: [Substring] = ["Atlas", "🛰️"]
            let foodtruck: [Substring] = ["food", "truck", "🚚"]
            let atlasCount = Task.detached {
                atlas.map(\\.count).reduce(0, +)
            }
            let foodtruckCount = Task.detached {
                foodtruck.map(\\.count).reduce(0, +)
            }
            let first = await atlasCount.value
            let second = await foodtruckCount.value
            return "\\(first):\\(second)"
        }
        await probe()
        """)

        #expect(value.stringValue == "6:10")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
    }

    @Test func detachedYieldUsesPhysicalSuspendingKernel() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func probe() async -> String {
            await Task.detached(priority: .background) {
                await Task.yield()
            }.value
            await Task.detached(priority: .background) {
                await Task.yield()
            }.value
            return "yielded:2"
        }
        await probe()
        """)

        #expect(value.stringValue == "yielded:2")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
    }

    @Test
    func immutableBooleanParameterConditionalSleepUsesPhysicalSuspendingKernel()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func waitForDetachedSleep(_ slow: Bool) async -> String {
            do {
                try await Task.detached {
                    try await Task.sleep(
                        for: slow ? .seconds(0) : .milliseconds(1))
                }.value
                return slow ? "slow" : "fast"
            } catch {
                return "error"
            }
        }

        @MainActor
        func probe() async -> String {
            let slow = await waitForDetachedSleep(true)
            let fast = await waitForDetachedSleep(false)
            return "\\(slow):\\(fast)"
        }
        await probe()
        """)

        #expect(value.stringValue == "slow:fast")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
    }

    @Test func cancelledPhysicalConditionalSleepThrowsCancellationError()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func probe() async -> String {
            let slow = true
            let task = Task.detached {
                try await Task.sleep(
                    for: slow ? .seconds(30) : .milliseconds(1))
            }
            task.cancel()
            do {
                try await task.value
                return "unexpected-value"
            } catch is CancellationError {
                return "cancelled:\\(task.isCancelled)"
            } catch {
                return "unexpected-error"
            }
        }
        await probe()
        """)

        #expect(value.stringValue == "cancelled:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
    }

    @Test func capturedStringIndexDistanceUsesPhysicalExpressionKernel()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func probe() async -> String {
            let atlas = "A🛰️BC"
            let location = atlas.index(atlas.startIndex, offsetBy: 2)
            let distance = Task.detached {
                atlas.distance(from: atlas.startIndex, to: location)
            }
            return "\\(await distance.value)"
        }
        await probe()
        """)

        #expect(value.stringValue == "2")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
    }

    @Test func cancelledPhysicalStringDistanceStillReturnsItsValue()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func probe() async -> String {
            let text = "A🛰️BC"
            let location = text.index(text.startIndex, offsetBy: 2)
            let task = Task.detached {
                text.distance(from: text.startIndex, to: location)
            }
            task.cancel()
            let distance = await task.value
            return "\\(distance):\\(task.isCancelled)"
        }
        await probe()
        """)

        #expect(value.stringValue == "2:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
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

    @Test func unsupportedStringArrayReductionsStayOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let globalStrings: [Substring] = ["global"]

        @MainActor
        func probe() async -> String {
            var mutableStrings: [Substring] = ["Atlas", "🛰️"]
            let localStrings: [Substring] = ["food", "truck", "🚚"]
            let mutableCount = Task.detached {
                mutableStrings.map(\\.count).reduce(0, +)
            }
            let globalCount = Task.detached {
                globalStrings.map(\\.count).reduce(0, +)
            }
            let alternateSeed = Task.detached {
                localStrings.map(\\.count).reduce(1, +)
            }
            let first = await mutableCount.value
            let second = await globalCount.value
            let third = await alternateSeed.value
            return "\\(first):\\(second):\\(third)"
        }
        await probe()
        """)

        #expect(value.stringValue == "6:6:11")
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

    @Test func unsupportedYieldClosuresStayOnTheCooperativeEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let authored = Task.detached { () async -> Void in
            await Task.yield()
        }
        let multiple = Task.detached {
            await Task.yield()
            await Task.yield()
        }
        await authored.value
        await multiple.value
        "fallback"
        """)

        #expect(value.stringValue == "fallback")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
    }

    @Test func unsupportedConditionalSleepsStayOnTheCooperativeEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let globalSlow = false

        @MainActor
        func probe(_ immutableSlow: Bool) async -> String {
            var mutableSlow = false
            let immutable = Task.detached {
                try await Task.sleep(
                    for: immutableSlow
                        ? .seconds(0) : .milliseconds(0))
            }
            let mutable = Task.detached {
                try await Task.sleep(
                    for: mutableSlow ? .seconds(0) : .milliseconds(0))
            }
            let global = Task.detached {
                try await Task.sleep(
                    for: globalSlow ? .seconds(0) : .milliseconds(0))
            }
            let alternate = Task.detached {
                try await Task.sleep(nanoseconds: 0)
            }
            let unsupportedUnit = Task.detached {
                try await Task.sleep(
                    for: immutableSlow
                        ? .microseconds(0) : .milliseconds(0))
            }
            try await immutable.value
            try await mutable.value
            try await global.value
            try await alternate.value
            try await unsupportedUnit.value
            return "completed"
        }
        try await probe(true)
        """)

        #expect(value.stringValue == "completed")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
    }

    @Test func unsupportedStringDistancesStayOnTheCooperativeEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        let globalText = "A🛰️B"
        let globalLocation = globalText.index(
            globalText.startIndex, offsetBy: 2)

        @MainActor
        func probe() async -> String {
            var mutableText = "A🛰️B"
            let mutableLocation = mutableText.index(
                mutableText.startIndex, offsetBy: 2)
            let localText = "A🛰️B"
            let alternateFrom = localText.index(
                localText.startIndex, offsetBy: 1)
            let localLocation = localText.index(
                localText.startIndex, offsetBy: 2)
            let mutable = Task.detached {
                mutableText.distance(
                    from: mutableText.startIndex, to: mutableLocation)
            }
            let global = Task.detached {
                globalText.distance(
                    from: globalText.startIndex, to: globalLocation)
            }
            let alternate = Task.detached {
                localText.distance(from: alternateFrom, to: localLocation)
            }
            let first = await mutable.value
            let second = await global.value
            let third = await alternate.value
            return "\\(first):\\(second):\\(third)"
        }
        await probe()
        """)

        #expect(value.stringValue == "2:2:1")
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
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 2)
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
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 2)
            #expect(cooperative.concurrencyRuntime.activeRecordCount == 0)
            #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
        }
    }

    @Test func capturedStringArrayCountModesRemainEquivalent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-captured-string-array-count.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelCapturedStringArrayCountProbe()\n"
        let configuration = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)

        for _ in 0..<20 {
            let cooperative = Interpreter()
            let parallel = Interpreter(
                executionMode: .parallel(configuration))
            let cooperativeValue = try await cooperative.runAsync(
                source: source)
            let parallelValue = try await parallel.runAsync(source: source)

            #expect(cooperativeValue.stringValue == "6:10")
            #expect(parallelValue.stringValue
                == cooperativeValue.stringValue)
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 2)
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 2)
            #expect(cooperative.concurrencyRuntime.activeRecordCount == 0)
            #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
        }
    }

    @Test func detachedYieldModesRemainEquivalent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-yield.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedYieldProbe()\n"
        let configuration = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)

        for _ in 0..<20 {
            let cooperative = Interpreter()
            let parallel = Interpreter(
                executionMode: .parallel(configuration))
            let cooperativeValue = try await cooperative.runAsync(
                source: source)
            let parallelValue = try await parallel.runAsync(source: source)

            #expect(cooperativeValue.stringValue == "yielded:2")
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

    @Test func detachedConditionalSleepModesRemainEquivalent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-conditional-sleep.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedConditionalSleepParityProbe()\n"
        let configuration = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)

        for _ in 0..<20 {
            let cooperative = Interpreter()
            let parallel = Interpreter(
                executionMode: .parallel(configuration))
            let cooperativeValue = try await cooperative.runAsync(
                source: source)
            let parallelValue = try await parallel.runAsync(source: source)

            #expect(cooperativeValue.stringValue
                == "slow:fast|cancelled:true")
            #expect(parallelValue.stringValue
                == cooperativeValue.stringValue)
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 2)
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 3)
            #expect(cooperative.concurrencyRuntime.activeRecordCount == 0)
            #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
        }
    }

    @Test func capturedStringDistanceModesRemainEquivalent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-captured-string-distance.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelCapturedStringDistanceParityProbe()\n"
        let configuration = try RuntimeParallelismConfiguration(
            maximumParallelism: 2)

        for _ in 0..<20 {
            let cooperative = Interpreter()
            let parallel = Interpreter(
                executionMode: .parallel(configuration))
            let cooperativeValue = try await cooperative.runAsync(
                source: source)
            let parallelValue = try await parallel.runAsync(source: source)

            #expect(cooperativeValue.stringValue == "2:5|2:true")
            #expect(parallelValue.stringValue
                == cooperativeValue.stringValue)
            #expect(cooperative.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 0)
            #expect(parallel.concurrencyRuntime
                .totalPhysicalSourceKernelExecutions == 3)
            #expect(cooperative.concurrencyRuntime.activeRecordCount == 0)
            #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
        }
    }
}
