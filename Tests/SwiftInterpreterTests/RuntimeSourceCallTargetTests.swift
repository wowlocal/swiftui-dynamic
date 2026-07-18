import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Runtime source call targets")
struct RuntimeSourceCallTargetTests {
    @Test
    func ownSourceMethodPublishesExactSendableOriginTarget()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/detached-source-member-call-target.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let interpreter = Interpreter()

        _ = try await interpreter.runAsync(source: source)

        let symbol = try #require(
            interpreter.structSymbols.first {
                $0.name == "StoreMessagesProbe"
            })
        let value = try interpreter.instantiate(
            symbol, with: CallArguments())
        guard case .instance(let instance) = value else {
            Issue.record("StoreMessagesProbe did not instantiate")
            return
        }
        let first = try #require(
            interpreter.resolveOwnSourceInstanceMethodCallTarget(
                named: "updatesLoop",
                on: instance,
                arguments: CallArguments()))
        let global = try #require(
            interpreter.globals.lookup("updatesLoop")?.closureValue?
                .sourceFunctionTargetDescriptor)

        #expect(first.descriptor.sourceFunctionName == "updatesLoop()")
        #expect(first.descriptor.declarationID
            == symbol.methods["updatesLoop"]?.first?.id)
        #expect(first.descriptor.declarationID != global.declarationID)
        #expect(first.descriptor.originProgramPlan
            === global.originProgramPlan)
        #expect(first.descriptor.lexicalPlacement == .lexicalType(
            name: "StoreMessagesProbe",
            isTypeMember: false,
            isActor: false))
        #expect(first.descriptor.isolation == .executor(.mainActor))
        #expect(first.descriptor.isAsync)
        #expect(!first.descriptor.isThrowing)
        #expect(first.descriptor.returnTypeName == "String")

        func requireSendable<T: Sendable>(_: T) {}
        let transferable = first.descriptor
        requireSendable(transferable)
        let detachedObservation = await Task.detached {
            (
                transferable.sourceFunctionName,
                transferable.lexicalPlacement,
                transferable.isolation,
                transferable.isAsync,
                transferable.isThrowing,
                transferable.returnTypeName,
                transferable.originProgramPlan.fileName
            )
        }.value
        #expect(detachedObservation.0 == "updatesLoop()")
        #expect(detachedObservation.1 == first.descriptor.lexicalPlacement)
        #expect(detachedObservation.2 == .executor(.mainActor))
        #expect(detachedObservation.3)
        #expect(!detachedObservation.4)
        #expect(detachedObservation.5 == "String")
        #expect(detachedObservation.6 == "input.swift")

        let invokedValue = try await interpreter.runAsync(
            source: "await detachedSourceMemberCallTargetProbe()")
        #expect(invokedValue.stringValue == "target:member")
        let second = try #require(
            interpreter.resolveOwnSourceInstanceMethodCallTarget(
                named: "updatesLoop",
                on: instance,
                arguments: CallArguments()))
        #expect(second.descriptor == first.descriptor)
        #expect(second.descriptor.originProgramPlan
            === first.descriptor.originProgramPlan)
    }

    @Test
    func sameShapeOverloadsDoNotFabricateADeclarationTarget() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        final class AmbiguousTarget {
            func select(_ value: Int) -> String { "int" }
            func select(_ value: String) -> String { "string" }
        }
        """)
        let symbol = try #require(
            interpreter.structSymbols.first {
                $0.name == "AmbiguousTarget"
            })
        let value = try interpreter.instantiate(
            symbol, with: CallArguments())
        guard case .instance(let instance) = value else {
            Issue.record("AmbiguousTarget did not instantiate")
            return
        }

        let unresolved = interpreter.resolveOwnSourceInstanceMethodCallTarget(
            named: "select",
            on: instance,
            arguments: CallArguments(arguments: [
                .init(label: nil, value: .native(7)),
            ]))

        #expect(unresolved == nil)
    }

    @Test
    func selectedMainActorSourceCallUsesAPhysicalWrapperAndConfinedReentry()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/detached-source-member-call-target.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait detachedSourceMemberCallTargetProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "target:member")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func sourceValueCopyPreservesItsOriginProgramState() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        struct ValueTarget {
            let value = 7
        }
        let retainedValueTarget = ValueTarget()
        """)
        guard case .instance(let value)? = interpreter.globals.lookup(
            "retainedValueTarget") else {
            Issue.record("retainedValueTarget was not materialized")
            return
        }

        let copy = value.copiedForValueSemantics()

        #expect(value.programState != nil)
        #expect(copy !== value)
        #expect(copy.programState === value.programState)
        #expect(copy.programState?.programPlan === value.programState?.programPlan)
    }

    @Test
    func physicalVoidReentryPreservesStateAndLogicalCancellation()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-mainactor-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedMainActorSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "1:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func concurrentSourceCallCopiesArgumentsAndReentersItsLogicalExecutor()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-concurrent-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedConcurrentSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "7:11|18:none")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func booleanLiteralMainActorSourceCallUsesPhysicalWrapper() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-mainactor-bool-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedMainActorBooleanSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "on:off|TF")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func synchronousActorSourceCallUsesPhysicalWrapperAndMailbox()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-actor-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedActorSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "actor|R")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func asynchronousActorSourceCallCopiesIntegerAndReentersMailbox()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-async-actor-int-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedAsyncActorIntegerSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "start:17|done:17")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func asynchronousDefaultedActorSourceCallCopiesBooleanAndReentersMailbox()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-async-defaulted-actor-bool-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedAsyncDefaultedActorBooleanSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "start:true|done:true")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func unsupportedIsolationAndResultFamiliesStayCooperative()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))
        let value = try await interpreter.runAsync(source: """
        @MainActor
        final class IsolationProbe {
            nonisolated func detachedValue() async -> String {
                "nonisolated"
            }

            func integerValue() async -> Int { 7 }

            func echo(_ value: Int) async -> String { "\\(value)" }

            func echoString(_ value: String) async -> String { value }

            func echoBool(_ value: Bool) async -> String {
                value ? "true" : "false"
            }

            func run() async -> String {
                let first = await Task.detached {
                    await self.detachedValue()
                }.value
                let second = await Task.detached {
                    await self.integerValue()
                }.value
                var mutable = 5
                let mutableArgument = await Task.detached {
                    await self.echo(mutable)
                }.value
                let expressionArgument = await Task.detached {
                    await self.echo(1 + 2)
                }.value
                let unsupportedScalar = await Task.detached {
                    await self.echoString("text")
                }.value
                let capturedBool = true
                let unsupportedBooleanCapture = await Task.detached {
                    await self.echoBool(capturedBool)
                }.value
                return "\\(first):\\(second):\\(mutableArgument):\\(expressionArgument):\\(unsupportedScalar):\\(unsupportedBooleanCapture)"
            }
        }

        actor ActorProbe {
            var booleanObservation = ""
            var defaultedBooleanObservation = ""
            var defaultedIntegerObservation = ""

            func value() async -> String { "actor" }

            func labeled(_ value: Int) -> String { "\\(value)" }

            func synchronousString() -> String { "sync" }

            func asynchronousBoolean(_ value: Bool) async {
                await Task.yield()
                booleanObservation = value ? "true" : "false"
            }

            func defaultedBoolean(_ value: Bool = false) async {
                await Task.yield()
                defaultedBooleanObservation += value ? "T" : "F"
            }

            func defaultedInteger(_ value: Int = 0) async {
                await Task.yield()
                defaultedIntegerObservation = "\\(value)"
            }

            func run() async -> String {
                let asynchronous = await Task.detached {
                    await self.value()
                }.value
                let argumentBearing = await Task.detached {
                    await self.labeled(7)
                }.value
                let unsupportedResult = await Task.detached {
                    await self.synchronousString()
                }.value
                await Task.detached {
                    await self.asynchronousBoolean(true)
                }.value
                await Task.detached {
                    await self.defaultedBoolean()
                }.value
                let capturedBoolean = true
                await Task.detached {
                    await self.defaultedBoolean(capturedBoolean)
                }.value
                await Task.detached {
                    await self.defaultedInteger(9)
                }.value
                return "\\(asynchronous):\\(argumentBearing):\\(unsupportedResult):\\(booleanObservation):\\(defaultedBooleanObservation):\\(defaultedIntegerObservation)"
            }
        }

        @MainActor
        func probe() async -> String {
            let isolated = await IsolationProbe().run()
            let actor = await ActorProbe().run()
            return "\\(isolated):\\(actor)"
        }

        await probe()
        """)

        #expect(value.stringValue
            == "nonisolated:7:5:3:text:true:actor:7:sync:true:FT:9")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func interpretedTrapDuringPhysicalReentryRemainsContained()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        do {
            _ = try await interpreter.runAsync(source: """
            @MainActor
            final class CrashingReentryProbe {
                func crash() async -> String {
                    fatalError("contained physical source call")
                }

                func run() async -> String {
                    await Task.detached {
                        await self.crash()
                    }.value
                }
            }

            await CrashingReentryProbe().run()
            """)
            Issue.record("expected interpreted source-call trap")
        } catch let thrown as InterpretedThrow {
            let error = try #require(
                thrown.value.hostPayload as? RuntimeError)
            #expect(error.fatal)
            #expect(error.message.contains("contained physical source call"))
        } catch {
            Issue.record("unexpected source-call failure: \(error)")
        }

        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func suspendedConfinedReentryRelinquishesItsWorkerPermit()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))
        let value = try await interpreter.runAsync(source: """
        @MainActor
        final class PermitHandoffProbe {
            var started = false
            var mayFinish = false

            func waitOnMainActor() async {
                started = true
                while !mayFinish {
                    await Task.yield()
                }
            }

            func run() async -> Int {
                let suspended = Task.detached {
                    await self.waitOnMainActor()
                }
                while !started {
                    await Task.yield()
                }
                let finite = Task.detached { 42 }
                let result = await finite.value
                mayFinish = true
                await suspended.value
                return result
            }
        }

        await PermitHandoffProbe().run()
        """)

        #expect(value.intValue == 42)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
