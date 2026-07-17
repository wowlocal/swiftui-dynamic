import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Generated Task concurrency surface", .serialized)
struct GeneratedTaskSurfaceTests {
    @Test
    func activeInterfaceMetadataDrivesTaskStaticDispatch() throws {
        #expect(Set(GeneratedConcurrencySurface.taskStaticDispatch.keys) == [
            "checkCancellation", "currentPriority", "detached",
            "immediate", "immediateDetached", "isCancelled", "name",
            "sleep", "yield",
        ])
        #expect(GeneratedConcurrencySurface.knownTaskStaticMembers.contains(
            "basePriority"))
        #expect(GeneratedConcurrencySurface.taskStaticMemberDeclarations
            .values.reduce(0) { $0 + $1.count } == 25)
        let staticDetached = try #require(
            GeneratedConcurrencySurface.taskStaticMemberDeclarations["detached"])
        #expect(staticDetached.count == 4)
        #expect(staticDetached.count {
            $0.parameters.contains { $0.label == "executorPreference" }
        } == 2)
        #expect(staticDetached.count {
            $0.parameters.contains {
                $0.name == "operation" && $0.type.contains("async throws")
            }
        } == 2)
        let sleep = try #require(
            GeneratedConcurrencySurface.taskStaticMemberDeclarations["sleep"])
        #expect(sleep.count == 4)
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
        for name in ["immediate", "immediateDetached"] {
            let declarations = try #require(
                GeneratedConcurrencySurface.taskStaticMemberDeclarations[name])
            #expect(declarations.count == 2)
            #expect(declarations.allSatisfy { declaration in
                declaration.parameters.contains {
                    $0.label == "executorPreference"
                        && $0.name == "taskExecutor"
                        && $0.type.hasPrefix("consuming ")
                        && $0.defaultValue == "nil"
                } && declaration.parameters.contains {
                    $0.name == "operation"
                        && $0.inheritsActorContext
                        && $0.hasIsolatedFunctionType
                }
            })
        }

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
    func generatedButUnsupportedTaskStaticMembersAreExplicit() {
        for member in [
            "CancellationError", "basePriority", "runDetached",
            "suspend", "withCancellationHandler", "withGroup",
        ] {
            do {
                _ = try Interpreter().run(source: "Task.\(member)")
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
    func unsupportedTaskEqualityAndSleepUntilAreExplicit() async {
        do {
            _ = try await Interpreter().runAsync(source: """
            let task = Task { 1 }
            task == task
            """)
            Issue.record("unsupported Task equality was absorbed")
        } catch {
            #expect(String(describing: error).contains("cannot compare"))
        }

        do {
            _ = try await Interpreter().runAsync(source: """
            try await Task.sleep(until: .now)
            """)
            Issue.record("unsupported Task.sleep(until:) was absorbed")
        } catch {
            #expect(String(describing: error).contains(
                "Task.sleep requires nanoseconds: or a supported Duration value"))
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
    func immediateTaskKindsRunTheirPrefixBeforeConstructionReturns()
        async throws {
        let result = try await Interpreter().runAsync(source: """
        var events: [String] = []
        let ordinary = Task.immediate(
            name: "ordinary", executorPreference: nil
        ) {
            events.append("ordinary-start:" + (Task.name ?? "nil"))
            await Task.yield()
            events.append("ordinary-finish")
            return 11
        }
        events.append("ordinary-after")
        let detached = Task.immediateDetached(
            name: "detached", executorPreference: nil
        ) {
            events.append("detached-start:" + (Task.name ?? "nil"))
            await Task.yield()
            events.append("detached-finish")
            return 22
        }
        events.append("detached-after")
        let ordinaryValue = await ordinary.value
        let detachedValue = await detached.value
        return events.joined(separator: "|")
            + ":\\(ordinaryValue):\\(detachedValue)"
        """)
        let output = try #require(result.stringValue)
        let ordinaryStart = try #require(
            output.range(of: "ordinary-start:ordinary"))
        let ordinaryAfter = try #require(
            output.range(of: "ordinary-after"))
        let detachedStart = try #require(
            output.range(of: "detached-start:detached"))
        let detachedAfter = try #require(
            output.range(of: "detached-after"))
        #expect(ordinaryStart.lowerBound < ordinaryAfter.lowerBound)
        #expect(detachedStart.lowerBound < detachedAfter.lowerBound)
        #expect(output.hasSuffix(":11:22"))
    }

    @Test
    @MainActor
    func immediateTaskKindsUseDistinctRuntimeInheritanceAndCleanUp()
        async throws {
        struct Snapshot {
            let kind: RuntimeTaskKind
            let parent: RuntimeTaskID?
            let taskLocalCount: Int
            let executor: RuntimeExecutorKind
            let callbackExecutor: RuntimeExecutorKind
        }

        let interpreter = Interpreter()
        var snapshots: [Snapshot] = []
        interpreter.globals.define(
            "inspectImmediateRuntimeTask",
            .hostFunction(HostFunction(
                name: "inspectImmediateRuntimeTask"
            ) { _, context in
                guard let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let record = interpreter.concurrencyRuntime.records[taskID]
                else {
                    throw RuntimeError(message:
                        "immediate operation lost its runtime task")
                }
                snapshots.append(Snapshot(
                    kind: record.kind,
                    parent: record.parent,
                    taskLocalCount: record.taskLocals.count,
                    executor: record.executorPreference,
                    callbackExecutor: context.sourceExecutor))
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        enum ImmediateRuntimeLocal {
            @TaskLocal static var value = "default"
        }
        return await ImmediateRuntimeLocal.$value.withValue("parent") {
            let ordinary = Task.immediate(executorPreference: nil) {
                inspectImmediateRuntimeTask()
                return ImmediateRuntimeLocal.value
            }
            let detached = Task.immediateDetached(executorPreference: nil) {
                inspectImmediateRuntimeTask()
                return ImmediateRuntimeLocal.value
            }
            return (await ordinary.value) + ":" + (await detached.value)
        }
        """)

        #expect(result.stringValue == "parent:default")
        #expect(snapshots.count == 2)
        #expect(snapshots[0].kind == .unstructured)
        #expect(snapshots[0].parent != nil)
        #expect(snapshots[0].taskLocalCount == 1)
        #expect(snapshots[0].executor == .mainActor)
        #expect(snapshots[0].callbackExecutor == .mainActor)
        #expect(snapshots[1].kind == .detached)
        #expect(snapshots[1].parent == nil)
        #expect(snapshots[1].taskLocalCount == 0)
        #expect(snapshots[1].executor == .mainActor)
        #expect(snapshots[1].callbackExecutor == .mainActor)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    @MainActor
    func immediateTaskKindsPreserveOperationExecutorAcrossSuspension()
        async throws {
        struct Snapshot {
            let phase: String
            let kind: RuntimeTaskKind
            let recordExecutor: RuntimeExecutorKind
            let callbackExecutor: RuntimeExecutorKind
        }

        let interpreter = Interpreter()
        var snapshots: [Snapshot] = []
        interpreter.globals.define(
            "inspectImmediateExecutor",
            .hostFunction(HostFunction(name: "inspectImmediateExecutor") {
                arguments, context in
                guard let phase = arguments.positional(0)?.stringValue,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let record = interpreter.concurrencyRuntime.records[taskID]
                else {
                    throw RuntimeError(message:
                        "immediate operation lost its executor context")
                }
                snapshots.append(Snapshot(
                    phase: phase,
                    kind: record.kind,
                    recordExecutor: record.executorPreference,
                    callbackExecutor: context.sourceExecutor))
                return .void
            }))

        let result = try await interpreter.runAsync(source: """
        @MainActor
        func immediateExecutorProbe() async -> Int {
            let ordinary = Task.immediate(executorPreference: nil) {
                inspectImmediateExecutor("ordinary-before")
                await Task.yield()
                inspectImmediateExecutor("ordinary-after")
                return 11
            }
            let detached = Task.immediateDetached(executorPreference: nil) {
                inspectImmediateExecutor("detached-before")
                await Task.yield()
                inspectImmediateExecutor("detached-after")
                return 22
            }
            return await ordinary.value + detached.value
        }
        return await immediateExecutorProbe()
        """)

        #expect(result.intValue == 33)
        #expect(Set(snapshots.map(\.phase)) == [
            "ordinary-before", "ordinary-after",
            "detached-before", "detached-after",
        ])
        #expect(snapshots.filter { $0.phase.hasPrefix("ordinary") }
            .allSatisfy { $0.kind == .unstructured })
        #expect(snapshots.filter { $0.phase.hasPrefix("detached") }
            .allSatisfy { $0.kind == .detached })
        #expect(snapshots.allSatisfy {
            $0.recordExecutor == .mainActor
                && $0.callbackExecutor == .mainActor
        })
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    @MainActor
    func immediateTaskKindsRejectUnsupportedOperationExecutors() async {
        for api in ["immediate", "immediateDetached"] {
            for source in [
                """
                func operation() async -> Int { 1 }
                let task = Task.\(api)(
                    executorPreference: nil, operation: operation
                )
                return await task.value
                """,
                """
                @concurrent
                nonisolated func operation() async -> Int { 1 }
                let task = Task.\(api)(
                    executorPreference: nil, operation: operation
                )
                return await task.value
                """,
                """
                @concurrent
                nonisolated func construct() async -> Int {
                    let task = Task.\(api)(executorPreference: nil) { 1 }
                    return await task.value
                }
                return await construct()
                """,
                """
                nonisolated func operationFactory() -> () async -> Int {
                    { 1 }
                }
                @MainActor
                func construct() async -> Int {
                    let operation = operationFactory()
                    let task = Task.\(api)(
                        executorPreference: nil, operation: operation
                    )
                    return await task.value
                }
                return await construct()
                """,
            ] {
                do {
                    _ = try await Interpreter().runAsync(source: source)
                    Issue.record(
                        "Task.\(api) accepted an unsupported operation executor")
                } catch {
                    #expect(String(describing: error).contains(
                        "Task.\(api) currently requires a MainActor-inherited "
                            + "operation invoked from MainActor"))
                }
            }
        }
    }

    @Test
    @MainActor
    func nonNilImmediateTaskExecutorPreferencesFailClosed() async {
        for api in ["immediate", "immediateDetached"] {
            do {
                _ = try await Interpreter().runAsync(source: """
                final class ProbeTaskExecutor: TaskExecutor {
                    func enqueue(_ job: consuming ExecutorJob) {
                        globalConcurrentExecutor.enqueue(job)
                    }
                }
                let executor = ProbeTaskExecutor()
                let task = Task.\(api)(executorPreference: executor) { 1 }
                return await task.value
                """)
                Issue.record(
                    "Task.\(api) silently ignored a nonnil executor preference")
            } catch {
                #expect(String(describing: error).contains(
                    "Task.\(api)(executorPreference:) is not supported yet"))
            }
        }
    }

    @Test
    @MainActor
    func immediateTaskKindsDoNotUseSynchronousCompatibility() {
        for api in ["immediate", "immediateDetached"] {
            do {
                _ = try Interpreter().run(source: """
                Task.\(api)(executorPreference: nil) { 1 }
                """)
                Issue.record(
                    "Task.\(api) used synchronous compatibility")
            } catch {
                #expect(String(describing: error).contains(
                    "immediate task creation requires runAsync"))
            }
        }
    }

    @Test
    @MainActor
    func namedTasksFailClosedOutsideCanonicalAsyncRuntime() {
        for taskCreation in [
            #"Task(name: "ordinary") { 1 }"#,
            #"Task(name: nil) { 1 }"#,
            #"Task.detached(name: "detached") { 1 }"#,
            #"Task.detached(name: nil) { 1 }"#,
            #"let name: String? = nil; Task(name: name) { 1 }"#,
        ] {
            do {
                _ = try Interpreter().run(source: taskCreation)
                Issue.record(
                    "named task creation ran through synchronous compatibility")
            } catch {
                #expect(String(describing: error).contains(
                    "Task creation requires runAsync"))
            }
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
        process.standardInput = FileHandle.nullDevice
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
