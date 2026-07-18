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

    @Test
    func sourceShadowedStringCountUsesOriginTargetAndStaysCooperative()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-shadowed-string-count.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let parallel = Interpreter(
            executionMode: .parallel(parallelism))

        _ = try await cooperative.runAsync(source: source)
        _ = try await parallel.runAsync(source: source)
        let invocation = "await parallelShadowedStringCountProbe()"
        let cooperativeValue = try await cooperative.runAsync(
            source: invocation)
        let parallelValue = try await parallel.runAsync(source: invocation)

        #expect(cooperativeValue.intValue == 41)
        #expect(parallelValue.intValue == cooperativeValue.intValue)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
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

    @Test
    func sourceShadowedArrayMapUsesOriginTargetAndStaysCooperative()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-shadowed-array-map.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let parallel = Interpreter(
            executionMode: .parallel(parallelism))

        _ = try await cooperative.runAsync(source: source)
        _ = try await parallel.runAsync(source: source)
        let invocation = "await parallelShadowedArrayMapProbe()"
        let cooperativeValue = try await cooperative.runAsync(
            source: invocation)
        let parallelValue = try await parallel.runAsync(source: invocation)

        #expect(cooperativeValue.intValue == 41)
        #expect(parallelValue.intValue == cooperativeValue.intValue)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
    }

    @Test
    func sourceShadowedArrayReduceUsesOriginTargetAndStaysCooperative()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-shadowed-array-reduce.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let parallel = Interpreter(
            executionMode: .parallel(parallelism))

        _ = try await cooperative.runAsync(source: source)
        _ = try await parallel.runAsync(source: source)
        let invocation = "await parallelShadowedArrayReduceProbe()"
        let cooperativeValue = try await cooperative.runAsync(
            source: invocation)
        let parallelValue = try await parallel.runAsync(source: invocation)

        #expect(cooperativeValue.intValue == 73)
        #expect(parallelValue.intValue == cooperativeValue.intValue)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
    }

    @Test
    func sourceShadowedSubstringCountUsesOriginTargetAndStaysCooperative()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-shadowed-substring-count.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let parallel = Interpreter(
            executionMode: .parallel(parallelism))

        _ = try await cooperative.runAsync(source: source)
        _ = try await parallel.runAsync(source: source)
        let invocation = "await parallelShadowedSubstringCountProbe()"
        let cooperativeValue = try await cooperative.runAsync(
            source: invocation)
        let parallelValue = try await parallel.runAsync(source: invocation)
        let controlInvocation = "await parallelStringCountControlProbe()"
        let cooperativeControl = try await cooperative.runAsync(
            source: controlInvocation)
        let parallelControl = try await parallel.runAsync(
            source: controlInvocation)

        #expect(cooperativeValue.intValue == 178)
        #expect(parallelValue.intValue == cooperativeValue.intValue)
        #expect(cooperativeControl.intValue == 3)
        #expect(parallelControl.intValue == cooperativeControl.intValue)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
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

    @Test func shadowedTaskYieldStaysOnTheCooperativeEvaluator() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-shadowed-task-yield.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelShadowedTaskYieldProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let parallel = Interpreter(
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "source")
        #expect(parallelValue.stringValue == cooperativeValue.stringValue)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
    }

    @Test func shadowedTaskSleepStaysOnTheCooperativeEvaluator() async throws {
        let source = """
        struct ShadowTaskSleepReceiver: Sendable {
            func sleep(for duration: Duration) async throws -> String {
                "source"
            }
        }

        @MainActor
        func probe() async throws -> String {
            let spawn = {
                (operation: @escaping @Sendable () async throws -> String) in
                Task.detached(operation: operation)
            }
            return try await {
                let Task = ShadowTaskSleepReceiver()
                let slow = false
                return try await spawn {
                    try await Task.sleep(
                        for: slow ? .seconds(0) : .milliseconds(0))
                }.value
            }()
        }
        try await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "source")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
    }

    @Test
    func shadowedTaskNanosecondsPrefixStaysOnTheCooperativeEvaluator()
        async throws
    {
        let source = """
        @MainActor var shadowNanosecondsObservations: [String] = []

        @MainActor
        func recordShadowNanoseconds(_ value: String) {
            shadowNanosecondsObservations.append(value)
        }

        struct ShadowTaskNanosecondsReceiver: Sendable {
            func sleep(nanoseconds: UInt64) async throws {
                await recordShadowNanoseconds("source")
            }
        }

        @MainActor
        func probe() async -> String {
            let spawn = {
                (operation: @escaping @Sendable () async -> Void) in
                Task.detached(operation: operation)
            }
            await {
                let Task = ShadowTaskNanosecondsReceiver()
                await spawn {
                    try? await Task.sleep(nanoseconds: 0)
                    await recordShadowNanoseconds("suffix")
                }.value
            }()
            return shadowNanosecondsObservations.joined(separator: ",")
        }
        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "source,suffix")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
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

    @Test
    func tryOptionalSleepPrefixReentersConfinedContinuation() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-try-optional-sleep-prefix.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedTryOptionalSleepPrefixProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func tryOptionalNanosecondsSleepPrefixReentersMainActorContinuation()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-try-optional-nanoseconds-sleep-prefix.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedTryOptionalNanosecondsSleepPrefixProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let value = try await interpreter.runAsync(source: source)

        #expect(cooperativeValue.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(value.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func signatureFreeTryOptionalNanosecondsSleepPrefixReentersMainActorContinuation()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-signature-free-try-optional-nanoseconds-sleep-prefix.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedSignatureFreeTryOptionalNanosecondsSleepPrefixProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let value = try await interpreter.runAsync(source: source)

        #expect(cooperativeValue.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(value.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func detachedMainActorRunUsesPhysicalWrapperAndConfinedContinuation()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-mainactor-run-continuation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedMainActorRunContinuationProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let value = try await interpreter.runAsync(source: source)

        #expect(cooperativeValue.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(value.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func sourceShadowedMainActorRunStaysOnTheCooperativeEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct MainActor {
            static func run(body: () -> String) async -> String {
                "source:" + body()
            }
        }

        func probe() async -> String {
            await Task.detached {
                await MainActor.run { "body" }
            }.value
        }
        await probe()
        """)

        #expect(value.stringValue == "source:body")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func explicitMainActorClosureUsesPhysicalWrapperAndConfinedContinuation()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-explicit-mainactor-continuation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedExplicitMainActorContinuationProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let value = try await interpreter.runAsync(source: source)

        #expect(cooperativeValue.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(value.stringValue
            == "completed:false,cancelled:true|false:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func unsupportedOrShadowedExplicitMainActorSignaturesStayCooperative()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let attributed = Interpreter(
            executionMode: .parallel(parallelism))
        let shadowed = Interpreter(
            executionMode: .parallel(parallelism))

        let attributedValue = try await attributed.runAsync(source: """
        func probe() async -> String {
            await Task.detached { @MainActor @Sendable in
                "attributed"
            }.value
        }
        await probe()
        """)
        let shadowedValue = try await shadowed.runAsync(source: """
        actor SourceMainActor {}

        @globalActor
        struct MainActor {
            static let shared = SourceMainActor()
        }

        func probe() async -> String {
            await Task.detached { @MainActor in
                "shadowed"
            }.value
        }
        await probe()
        """)

        #expect(attributedValue.stringValue == "attributed")
        #expect(shadowedValue.stringValue == "shadowed")
        #expect(attributed.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(attributed.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(shadowed.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(shadowed.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(attributed.concurrencyRuntime.activeRecordCount == 0)
        #expect(shadowed.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func weakTryOptionalDurationSleepPrefixReentersActorContinuation()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-weak-try-optional-sleep-prefix.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedWeakTryOptionalSleepPrefixProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let value = try await interpreter.runAsync(source: source)

        #expect(cooperativeValue.stringValue
            == "group-a:false,group-b:true|false:true")
        #expect(value.stringValue
            == "group-a:false,group-b:true|false:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func unsupportedWeakSleepPrefixShapesStayOnCooperativeEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        actor WeakPrefixNegativeProbe {
            func mark(_ input: String) {}

            func run() async {
                let duration = Duration.milliseconds(0)
                let capturedDuration = Task.detached { [weak self] in
                    try? await Task.sleep(for: duration)
                    await self?.mark("captured-duration")
                }
                await capturedDuration.value

                let extraCapture = Task.detached { [weak self, duration] in
                    try? await Task.sleep(for: .milliseconds(0))
                    await self?.mark("extra-capture")
                }
                await extraCapture.value
            }
        }

        let probe = WeakPrefixNegativeProbe()
        await probe.run()
        "completed"
        """)

        #expect(value.stringValue == "completed")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func explicitMainActorRunResultTypeFailsClosed() async throws {
        let interpreter = Interpreter()

        do {
            _ = try await interpreter.runAsync(source: """
            await MainActor.run(resultType: String.self) {
                "unsupported"
            }
            """)
            Issue.record("expected explicit-result MainActor.run diagnostic")
        } catch let runtime as RuntimeError {
            #expect(runtime.message.contains(
                "MainActor.run(resultType:body:) is unsupported"))
        } catch {
            Issue.record("unexpected MainActor.run failure: \(error)")
        }
    }

    @Test func generatedMainActorRunIdentityDoesNotCaptureSourceShadow()
        async throws
    {
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: """
        struct MainActor {
            static func run(body: () -> String) -> String {
                "source:" + body()
            }
        }
        MainActor.run { "body" }
        """)

        #expect(value.stringValue == "source:body")
    }

    @Test func generatedMainActorUnroutedMemberFailsClosed() async throws {
        let probes = [
            ("MainActor.assumeIsolated { \"unsupported\" }",
             "MainActor.assumeIsolated"),
            ("MainActor.sharedUnownedExecutor",
             "MainActor.sharedUnownedExecutor"),
            ("MainActor.shared.unownedExecutor",
             "MainActor.unownedExecutor"),
            ("MainActor.shared.enqueue", "MainActor.enqueue"),
        ]

        for (source, expectedMember) in probes {
            let interpreter = Interpreter()
            do {
                _ = try await interpreter.runAsync(source: source)
                Issue.record(
                    "expected generated \(expectedMember) diagnostic")
            } catch let runtime as RuntimeError {
                #expect(runtime.message.contains(expectedMember))
                #expect(runtime.message.contains(
                    "declared by the active _Concurrency.swiftinterface"))
            } catch {
                Issue.record(
                    "unexpected \(expectedMember) failure: \(error)")
            }
        }
    }

    @Test
    func confinedSleepContinuationReleasesPermitBeforeNestedPhysicalWork()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        func nestedPhysicalWork() async -> String {
            await Task.detached { "nested" }.value
        }

        let outer = Task.detached {
            try? await Task.sleep(for: .milliseconds(0))
            await nestedPhysicalWork()
        }
        await outer.value
        """)

        #expect(value.stringValue == "nested")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func unsupportedSleepPrefixShapesStayOnCooperativeEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        @MainActor
        func mark() async {
            await Task.yield()
        }

        let plainTry = Task.detached {
            try await Task.sleep(for: .milliseconds(0))
            await mark()
        }
        _ = try? await plainTry.value

        let forcedTry = Task.detached {
            try! await Task.sleep(for: .milliseconds(0))
            await mark()
        }
        await forcedTry.value

        let nanoseconds = 0
        let capturedNanoseconds = Task.detached {
            try? await Task.sleep(nanoseconds: nanoseconds)
            await mark()
        }
        await capturedNanoseconds.value

        let unsupportedUnit = Task.detached {
            try? await Task.sleep(for: .microseconds(0))
            await mark()
        }
        await unsupportedUnit.value

        let threeItems = Task.detached {
            try? await Task.sleep(for: .milliseconds(0))
            await mark()
            await mark()
        }
        await threeItems.value

        let reversed = Task.detached {
            await mark()
            try? await Task.sleep(for: .milliseconds(0))
        }
        await reversed.value

        let authored = Task.detached { () async -> Void in
            try? await Task.sleep(for: .milliseconds(0))
            await mark()
        }
        await authored.value
        "completed"
        """)

        #expect(value.stringValue == "completed")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func interpretedTrapInConfinedSleepContinuationRemainsContained()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        do {
            _ = try await interpreter.runAsync(source: """
            @MainActor
            func crashAfterPhysicalSleep() async -> String {
                fatalError("contained physical sleep continuation")
            }

            await Task.detached {
                try? await Task.sleep(for: .milliseconds(0))
                await crashAfterPhysicalSleep()
            }.value
            """)
            Issue.record("expected interpreted sleep-continuation trap")
        } catch let thrown as InterpretedThrow {
            let error = try #require(
                thrown.value.hostPayload as? RuntimeError)
            #expect(error.fatal)
            #expect(error.message.contains(
                "contained physical sleep continuation"))
        } catch {
            Issue.record("unexpected sleep-continuation failure: \(error)")
        }

        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
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

    @Test
    func sourceShadowedStringDistanceUsesOriginTargetAndStaysCooperative()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-shadowed-string-distance.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let parallel = Interpreter(
            executionMode: .parallel(parallelism))

        _ = try await cooperative.runAsync(source: source)
        _ = try await parallel.runAsync(source: source)
        let invocation = "await parallelShadowedStringDistanceProbe()"
        let cooperativeValue = try await cooperative.runAsync(
            source: invocation)
        let parallelValue = try await parallel.runAsync(source: invocation)

        #expect(cooperativeValue.intValue == 77)
        #expect(parallelValue.intValue == cooperativeValue.intValue)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
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
