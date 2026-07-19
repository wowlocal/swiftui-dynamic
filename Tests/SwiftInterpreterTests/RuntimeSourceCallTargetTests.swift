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
    func customGlobalActorSourceCallPreservesExecutorAndReentersMailbox()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-custom-global-actor-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedCustomGlobalActorSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))
        interpreter.globals.define(
            "parityCurrentIsolationMatches",
            .hostFunction(HostFunction(
                name: "parityCurrentIsolationMatches"
            ) { arguments, _ in
                let isolation = try interpreter.currentSourceIsolationValue()
                guard case .instance(let expected)? = arguments.positional(0),
                      case .instance(let actual)? =
                        isolation.unwrappedOptionalOrSelf,
                      let expectedID = expected.actorID,
                      let actualID = actual.actorID else {
                    return .native("other")
                }
                return .native(expectedID == actualID ? "same" : "other")
            }))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "same|same")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 1)
        #expect(interpreter.concurrencyRuntime.actors.values.allSatisfy {
            $0.executorOwnerTaskID == nil && $0.mailboxTaskIDs.isEmpty
        })
    }

    @Test
    func inheritedSourceCallUsesCallerExecutorAndPhysicalWrapper()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-inherited-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedInheritedSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "none|none")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func inheritedStringSourceCallCopiesArgumentAndUsesPhysicalWrapper()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-inherited-string-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedInheritedStringSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "bafy-planet:none|none")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func nonisolatedSynchronousURLSourceCallCopiesArgumentAndUsesPhysicalWrapper()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-nonisolated-url-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedNonisolatedURLSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "loaded:first.mp4,second.mp4")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func nonisolatedSynchronousURLStoredLetSourceCallCopiesArgumentAndUsesPhysicalWrapper()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-nonisolated-url-member-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedNonisolatedURLMemberSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "loaded:first-member.mp4,second-member.mp4")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func staticStringSourceCallCopiesCaptureAndUsesPhysicalWrapper()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-static-string-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedStaticStringSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "prepared:FIRST-SCRIPT,prepared:SECOND-SCRIPT")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func staticStringSourceCallModesRemainEquivalent() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-static-string-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedStaticStringSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter()
        let parallel = Interpreter(
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue
            == "prepared:FIRST-SCRIPT,prepared:SECOND-SCRIPT")
        #expect(parallelValue.stringValue == cooperativeValue.stringValue)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(cooperative.concurrencyRuntime.activeRecordCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func staticProtocolDefaultPublishesExactSendableOriginTarget() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-static-string-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let interpreter = Interpreter()
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.structSymbols.first {
            $0.name == "PhysicalStaticStringSourceCallProbe"
        })
        let target = try #require(
            interpreter.resolveUniqueProtocolExtensionStaticMethodCallTarget(
                named: "prepareScriptSource",
                onConformingType: symbol,
                arguments: CallArguments(arguments: [
                    .init(label: "from", value: .native("probe")),
                ])))

        #expect(target.descriptor.sourceFunctionName
            == "prepareScriptSource(from:)")
        #expect(target.descriptor.lexicalPlacement == .lexicalType(
            name: "PhysicalStaticStringSourceCallProtocol",
            isTypeMember: true,
            isActor: false))
        #expect(target.descriptor.isolation == .explicitlyNonisolated)
        #expect(!target.descriptor.isAsync)
        #expect(!target.descriptor.isThrowing)
        #expect(target.descriptor.returnTypeName == "String")
        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(target.descriptor)
    }

    @Test
    func staticProtocolExtensionSourceCallIsSemanticallyExactCooperatively()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-static-string-source-call.swift")
        let fixtureSource = try String(contentsOf: fixture, encoding: .utf8)

        let directInterpreter = Interpreter()
        let direct = try await directInterpreter.runAsync(source:
            fixtureSource
                + "\nPhysicalStaticStringSourceCallProbe"
                + ".prepareScriptSource(from: \"direct\")\n")
        #expect(direct.stringValue == "prepared:DIRECT")

        let defaultDirectInterpreter = Interpreter()
        let defaultDirect = try await defaultDirectInterpreter.runAsync(
            source: fixtureSource
                + "\nPhysicalStaticStringSourceCallProbe("
                + "source: \"default-direct\").prepareDirectly()\n")
        #expect(defaultDirect.stringValue == "prepared:DEFAULT-DIRECT")

        let resultGetInterpreter = Interpreter()
        let resultGet = try await resultGetInterpreter.runAsync(
            source: fixtureSource + "\nawait detachedResultGetProbe()\n")
        #expect(resultGet.stringValue == "result-get")

        let defaultInterpreter = Interpreter()
        let defaultMethod = try await defaultInterpreter.runAsync(source:
            fixtureSource
                + "\nawait PhysicalStaticStringSourceCallProbe("
                + "source: \"default\").prepare()\n")
        #expect(defaultMethod.stringValue == "prepared:DEFAULT")
        #expect(defaultInterpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(defaultInterpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
    }

    @Test
    func taskResultGetEvaluatesDetachedBaseExactlyOnce() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-static-string-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait detachedResultGetProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "result-get")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func richerStaticStringSourceCallShapesStayCooperative() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))
        let value = try await interpreter.runAsync(source: #"""
        protocol StaticStringRouteProtocol: Sendable {}

        protocol ConstrainedStaticStringRouteProtocol: Sendable {
            associatedtype Payload
        }

        extension StaticStringRouteProtocol {
            nonisolated static func prepare(from source: String) -> String {
                "default:\(source)"
            }

            static func inherited(from source: String) -> String {
                "inherited:\(source)"
            }

            nonisolated static func prepareAsync(
                from source: String
            ) async -> String {
                "async:\(source)"
            }
        }

        extension ConstrainedStaticStringRouteProtocol where Payload == String {
            nonisolated static func constrained(
                from source: String
            ) -> String {
                "constrained:\(source)"
            }
        }

        struct StaticStringRouteProbe: StaticStringRouteProtocol {
            nonisolated static func prepare(from source: String) -> String {
                "own:\(source)"
            }

            func run() async -> String {
                let source = "script"
                let suffix = "!"
                let implicit = Task.detached {
                    Self.inherited(from: source)
                }
                let multiple = Task.detached { [source, suffix] in
                    Self.inherited(from: source) + suffix
                }
                let attributed = Task.detached { @Sendable [source] in
                    Self.inherited(from: source)
                }
                let concrete = Task.detached { [source] in
                    StaticStringRouteProbe.prepare(from: source)
                }
                let inherited = Task.detached { [source] in
                    Self.inherited(from: source)
                }
                let asynchronous = Task.detached { [source] in
                    await Self.prepareAsync(from: source)
                }
                let implicitValue = await implicit.value
                let multipleValue = await multiple.value
                let attributedValue = await attributed.value
                let concreteValue = await concrete.value
                let inheritedValue = await inherited.value
                let asynchronousValue = await asynchronous.value
                return [
                    implicitValue,
                    multipleValue,
                    attributedValue,
                    concreteValue,
                    inheritedValue,
                    asynchronousValue,
                ].joined(separator: "|")
            }
        }

        struct ConstrainedStaticStringRouteProbe:
            ConstrainedStaticStringRouteProtocol
        {
            typealias Payload = String
            let source: String

            func run() async -> String {
                await Task.detached { [source] in
                    Self.constrained(from: source)
                }.value
            }
        }

        let ordinary = await StaticStringRouteProbe().run()
        let constrained = await ConstrainedStaticStringRouteProbe(
            source: "script"
        ).run()
        "\(ordinary)|\(constrained)"
        """#)

        #expect(value.stringValue
            == "inherited:script|inherited:script!|inherited:script|"
                + "own:script|inherited:script|async:script|"
                + "constrained:script")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func richerNonisolatedURLSourceCallShapesStayCooperative() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))
        let value = try await interpreter.runAsync(source: """
        import Foundation

        struct UnsupportedURLContainer {
            let url: URL
        }

        @MainActor
        final class UnsupportedNonisolatedURLRoutes {
            nonisolated(unsafe) var mutableMemberURL = URL(
                fileURLWithPath: "/tmp/mutable-member.mp4")
            nonisolated var computedMemberURL: URL {
                URL(fileURLWithPath: "/tmp/computed-member.mp4")
            }
            nonisolated(unsafe) lazy var lazyMemberURL = URL(
                fileURLWithPath: "/tmp/lazy-member.mp4")
            @available(*, deprecated)
            let attributedMemberURL = URL(
                fileURLWithPath: "/tmp/attributed-member.mp4")
            let nestedMemberURL = UnsupportedURLContainer(
                url: URL(fileURLWithPath: "/tmp/nested-member.mp4"))

            nonisolated func consume(url: URL) {
                precondition(url.lastPathComponent.hasSuffix(".mp4"))
            }

            nonisolated func consumeAsync(url: URL) async {
                precondition(url.lastPathComponent.hasSuffix(".mp4"))
            }

            func mainActorAsync(url: URL) async {
                precondition(url.lastPathComponent.hasSuffix(".mp4"))
            }

            @concurrent
            func concurrentAsync(url: URL) async {
                precondition(url.lastPathComponent.hasSuffix(".mp4"))
            }

            nonisolated func project(url: URL) -> String {
                url.lastPathComponent
            }

            func run() async -> String {
                var mutableURL = URL(fileURLWithPath: "/tmp/mutable.mp4")
                await Task.detached {
                    self.consume(url: mutableURL)
                }.value
                await Task.detached {
                    self.consume(url: URL(
                        fileURLWithPath: "/tmp/expression.mp4"))
                }.value
                let asyncURL = URL(fileURLWithPath: "/tmp/async.mp4")
                await Task.detached {
                    await self.consumeAsync(url: asyncURL)
                }.value
                let mainActorURL = URL(
                    fileURLWithPath: "/tmp/main-actor.mp4")
                await Task.detached {
                    await self.mainActorAsync(url: mainActorURL)
                }.value
                let concurrentURL = URL(
                    fileURLWithPath: "/tmp/concurrent.mp4")
                await Task.detached {
                    await self.concurrentAsync(url: concurrentURL)
                }.value
                let projectedURL = URL(fileURLWithPath: "/tmp/value.mp4")
                let projected = await Task.detached {
                    self.project(url: projectedURL)
                }.value
                await Task.detached {
                    self.consume(url: self.mutableMemberURL)
                }.value
                await Task.detached {
                    self.consume(url: self.computedMemberURL)
                }.value
                await Task.detached {
                    self.consume(url: self.lazyMemberURL)
                }.value
                await Task.detached {
                    self.consume(url: self.attributedMemberURL)
                }.value
                await Task.detached {
                    self.consume(url: self.nestedMemberURL.url)
                }.value
                return "\\(mutableURL.lastPathComponent):\\(projected):"
                    + "\\(mutableMemberURL.lastPathComponent):"
                    + "\\(computedMemberURL.lastPathComponent):"
                    + "\\(lazyMemberURL.lastPathComponent):"
                    + "\\(attributedMemberURL.lastPathComponent):"
                    + "\\(nestedMemberURL.url.lastPathComponent)"
            }
        }

        await UnsupportedNonisolatedURLRoutes().run()
        """)

        #expect(value.stringValue == "mutable.mp4:value.mp4:mutable-member.mp4:computed-member.mp4:lazy-member.mp4:attributed-member.mp4:nested-member.mp4")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func inheritedTryOptionalSourceCallContainsThrowAndUsesPhysicalWrapper()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-inherited-try-optional-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedInheritedTryOptionalSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue ==
            "success:none|none#some|failure:none|none#nil")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func unsupportedTryOptionalSourceCallRoutesStayCooperative() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        final class TryOptionalRouteControl: @unchecked Sendable {
            private var observation = ""

            @MainActor
            private func record(_ value: String) {
                if !observation.isEmpty { observation += "|" }
                observation += value
            }

            func plainTry() async throws {
                await Task.yield()
                await record("plain")
            }

            func forcedTry() async throws {
                await Task.yield()
                await record("force")
            }

            func argument(_ value: String) async throws {
                await Task.yield()
                await record(value)
            }

            func richerResult() async throws -> String {
                await Task.yield()
                await record("richer")
                return "value"
            }

            @MainActor
            func mainActor() async throws {
                await Task.yield()
                record("main")
            }

            @concurrent
            nonisolated func concurrent() async throws {
                await Task.yield()
                await record("concurrent")
            }

            func weakCall() async throws {
                await Task.yield()
                await record("weak")
            }

            func run() async -> String {
                _ = try? await Task.detached {
                    try await self.plainTry()
                }.value
                _ = await Task.detached {
                    try! await self.forcedTry()
                }.value
                _ = await Task.detached {
                    try? await self.argument("argument")
                }.value
                let richer = await Task.detached {
                    try? await self.richerResult()
                }.value
                _ = await Task.detached {
                    try? await self.mainActor()
                }.value
                _ = await Task.detached {
                    try? await self.concurrent()
                }.value
                _ = await Task.detached { [weak self] in
                    try? await self?.weakCall()
                }.value
                return await output() + ":" + (richer ?? "nil")
            }

            @MainActor
            private func output() -> String { observation }
        }

        await TryOptionalRouteControl().run()
        """)

        #expect(value.stringValue ==
            "plain|force|argument|richer|main|concurrent|weak:value")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func unsupportedStringSourceCallArgumentsStayCooperative() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        final class StringSourceCallRouteControl: @unchecked Sendable {
            private var observation = ""

            @MainActor
            private func record(_ value: String) {
                if !observation.isEmpty { observation += "|" }
                observation += value
            }

            func inherited(_ value: String) async {
                await Task.yield()
                await record("inherited:\\(value)")
            }

            @MainActor
            func mainActor(_ value: String) async {
                await Task.yield()
                record("main:\\(value)")
            }

            @concurrent
            nonisolated func concurrent(_ value: String) async {
                await Task.yield()
                await record("concurrent:\\(value)")
            }

            func run() async -> String {
                await Task.detached {
                    await self.inherited("literal")
                }.value

                var mutable = "mutable"
                await Task.detached {
                    await self.inherited(mutable)
                }.value

                let main = "main"
                await Task.detached {
                    await self.mainActor(main)
                }.value

                let worker = "worker"
                await Task.detached {
                    await self.concurrent(worker)
                }.value

                return await result()
            }

            @MainActor
            private func result() -> String {
                observation
            }
        }

        await StringSourceCallRouteControl().run()
        """)

        #expect(value.stringValue ==
            "inherited:literal|inherited:mutable|main:main|concurrent:worker")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func weakConcurrentStringSourceCallCopiesArgumentAndUsesPhysicalWrapper()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-weak-concurrent-string-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedWeakConcurrentStringSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "cover-cache:none|none#some")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func queuedWeakConcurrentStringWrapperDoesNotRetainReceiver() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))
        let driver = try #require(interpreter.physicalWorkerDriver)
        let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
        let capability = try entry.makeWorkerCapability(copying: [])
        let gate = DeferredWeakSourceCallPermitGate()
        let blockingJob = RuntimePhysicalWorkerJob(
            capability: capability
        ) { _ in
            await gate.block()
            return .void
        }
        let blocker = Task.detached {
            try await driver.execute([blockingJob])
        }
        await gate.waitUntilEntered()

        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: """
            final class QueuedWeakConcurrentStringProbe: @unchecked Sendable {
                @concurrent
                nonisolated func loadImageAndCacheIt(imagePath: String) async {}

                func launch(imagePath: String) -> Task<Void?, Never> {
                    Task.detached(priority: .high) { [weak self] in
                        await self?.loadImageAndCacheIt(imagePath: imagePath)
                    }
                }
            }

            func queuedWeakConcurrentStringProbe() async -> String {
                var receiver: QueuedWeakConcurrentStringProbe? =
                    QueuedWeakConcurrentStringProbe()
                let task = receiver!.launch(imagePath: "cover-cache")
                receiver = nil
                if let _ = await task.value {
                    return "retained"
                }
                return "released"
            }

            await queuedWeakConcurrentStringProbe()
            """)
        }

        var observedQueuedSubmission = false
        for _ in 0..<10_000 {
            if interpreter.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 1 {
                observedQueuedSubmission = true
                break
            }
            await Task.yield()
        }
        #expect(observedQueuedSubmission,
            "weak String wrapper never queued behind the occupied permit")
        await gate.release()

        #expect(try await blocker.value == [.void])
        let value = try await evaluation.value
        #expect(value.stringValue == "released")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func unsupportedWeakStringSourceCallRoutesStayCooperative() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        final class WeakStringSourceCallRouteControl: @unchecked Sendable {
            private var observation = ""

            @MainActor
            private func record(_ value: String) {
                if !observation.isEmpty { observation += "|" }
                observation += value
            }

            @concurrent
            nonisolated func concurrent(_ value: String) async {
                await Task.yield()
                await record("concurrent:\\(value)")
            }

            func inherited(_ value: String) async {
                await Task.yield()
                await record("inherited:\\(value)")
            }

            @MainActor
            func mainActor(_ value: String) async {
                await Task.yield()
                record("main:\\(value)")
            }

            func run() async -> String {
                await Task.detached { [weak self] in
                    await self?.concurrent("literal")
                }.value

                var mutable = "mutable"
                await Task.detached { [weak self] in
                    await self?.concurrent(mutable)
                }.value

                var inherited = "inherited"
                await Task.detached { [weak self] in
                    await self?.inherited(inherited)
                }.value

                let main = "main"
                await Task.detached { [weak self] in
                    await self?.mainActor(main)
                }.value

                return await result()
            }

            @MainActor
            private func result() -> String {
                observation
            }
        }

        await WeakStringSourceCallRouteControl().run()
        """)

        #expect(value.stringValue ==
            "concurrent:literal|concurrent:mutable|inherited:inherited|main:main")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func weakInheritedStringLiteralSourceCallUsesPhysicalWrapper() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-weak-inherited-string-literal-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedWeakInheritedStringLiteralSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "timeout:none|none#some")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func weakInheritedCapturedStringSourceCallUsesPhysicalWrapper() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-weak-inherited-captured-string-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedWeakInheritedCapturedStringSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "session-message:none|none#some")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func weakInheritedStringArraySourceCallUsesPhysicalWrapper() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-weak-inherited-string-array-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedWeakInheritedStringArraySourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "Applications,WebApps:none|none#some")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func unsupportedStringArraySourceCallRoutesStayCooperative() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        final class StringArrayRouteControl: @unchecked Sendable {
            private var observation = ""

            @MainActor
            private func record(_ value: String) {
                if !observation.isEmpty { observation += "|" }
                observation += value
            }

            func inherited(_ values: [String]) async {
                await Task.yield()
                await record("inherited:\\(values[0])")
            }

            @concurrent
            nonisolated func concurrent(_ values: [String]) async {
                await Task.yield()
                await record("concurrent:\\(values[0])")
            }

            @MainActor
            func mainActor(_ values: [String]) async {
                await Task.yield()
                record("main:\\(values[0])")
            }

            func launchDirect(_ values: [String]) -> Task<Void, Never> {
                Task.detached { await self.inherited(values) }
            }

            func launchConcurrent(_ values: [String]) -> Task<Void?, Never> {
                Task.detached { [weak self] in
                    await self?.concurrent(values)
                }
            }

            func launchMainActor(_ values: [String]) -> Task<Void?, Never> {
                Task.detached { [weak self] in
                    await self?.mainActor(values)
                }
            }

            func run() async -> String {
                await launchDirect(["direct"]).value
                await launchConcurrent(["concurrent"]).value
                await launchMainActor(["main"]).value
                return await result()
            }

            @MainActor
            private func result() -> String { observation }
        }

        await StringArrayRouteControl().run()
        """)

        #expect(value.stringValue ==
            "inherited:direct|concurrent:concurrent|main:main")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func strongSelfCaptureSourceCallUsesPhysicalWrapper() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-strong-self-capture-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedStrongSelfCaptureSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "strong:none|none")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func weakSelfCaptureSourceCallUsesDeferredPhysicalWrapper() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/parallel-detached-weak-self-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait parallelDetachedWeakSelfSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "weak:none|none")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func queuedWeakSelfPhysicalWrapperDoesNotRetainReceiver() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))
        let driver = try #require(interpreter.physicalWorkerDriver)
        let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
        let capability = try entry.makeWorkerCapability(copying: [])
        let gate = DeferredWeakSourceCallPermitGate()
        let blockingJob = RuntimePhysicalWorkerJob(
            capability: capability
        ) { _ in
            await gate.block()
            return .void
        }
        let blocker = Task.detached {
            try await driver.execute([blockingJob])
        }
        await gate.waitUntilEntered()

        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(source: """
            final class QueuedWeakSourceCallProbe: @unchecked Sendable {
                func processQueue() async {}

                func launch() -> Task<Void?, Never> {
                    Task.detached(priority: .background) { [weak self] in
                        await self?.processQueue()
                    }
                }
            }

            func queuedWeakSourceCallProbe() async -> String {
                var receiver: QueuedWeakSourceCallProbe? =
                    QueuedWeakSourceCallProbe()
                let task = receiver!.launch()
                receiver = nil
                if let _ = await task.value {
                    return "retained"
                }
                return "released"
            }

            await queuedWeakSourceCallProbe()
            """)
        }

        var observedQueuedSubmission = false
        for _ in 0..<10_000 {
            if interpreter.concurrencyRuntime
                .totalPhysicalSourceKernelSubmissions == 1 {
                observedQueuedSubmission = true
                break
            }
            await Task.yield()
        }
        #expect(observedQueuedSubmission,
            "weak source wrapper never queued behind the occupied permit")
        await gate.release()

        #expect(try await blocker.value == [.void])
        let value = try await evaluation.value
        #expect(value.stringValue == "released")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func weakSelfOptionalAsyncSourceCallStaysCooperativeAndSuspends()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/weak-self-optional-async-source-call.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait weakSelfOptionalAsyncSourceCallProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "alive:none|none|nil")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func optionalAsyncClosureInvocationStaysCooperativeAndSuspends()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/optional-async-closure-invocation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait optionalAsyncClosureInvocationProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "live:7:none|none|nil")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func weakReceiverReleasesWhileDetachedTaskIsSuspended() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/weak-receiver-release-across-suspension.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait weakReceiverReleaseAcrossSuspensionProbe()\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "released")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func customExecutorGlobalActorSourceCallStaysCooperative() async throws {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        do {
            _ = try await interpreter.runAsync(source: """
            @globalActor
            actor UnsupportedCustomExecutorGlobalActor {
                static let shared = UnsupportedCustomExecutorGlobalActor()

                nonisolated var unownedExecutor: UnownedSerialExecutor {
                    fatalError("must not evaluate custom executor")
                }
            }

            final class UnsupportedCustomExecutorGlobalActorProbe:
                @unchecked Sendable
            {
                @UnsupportedCustomExecutorGlobalActor
                func update() async {
                    await Task.yield()
                }

                func run() async {
                    await Task.detached {
                        await self.update()
                    }.value
                }
            }

            await UnsupportedCustomExecutorGlobalActorProbe().run()
            """)
            Issue.record("custom global-actor executor was physically admitted")
        } catch let thrown as InterpretedThrow {
            let error = try #require(
                thrown.value.hostPayload as? RuntimeError)
            #expect(error.fatal)
            #expect(error.message.contains("custom actor executor"))
            #expect(error.message.contains(
                "UnsupportedCustomExecutorGlobalActor"))
        } catch {
            Issue.record("unexpected custom-executor failure: \(error)")
        }

        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
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

        @globalActor
        actor UnsupportedNominalGlobalActor {
            static let shared = UnsupportedNominalGlobalActor()
        }

        actor UnsupportedWrappedGlobalActorExecutor {}

        @globalActor
        struct UnsupportedWrappedGlobalActor {
            static let shared = UnsupportedWrappedGlobalActorExecutor()
        }

        @globalActor
        enum UnsupportedEnumGlobalActor {
            static let shared = UnsupportedWrappedGlobalActorExecutor()
        }

        final class UnsupportedNominalGlobalActorProbe:
            @unchecked Sendable
        {
            var observation = ""

            @UnsupportedNominalGlobalActor
            func argumentBearing(_ value: Int) async {
                await Task.yield()
                observation = "\\(value)"
            }

            @UnsupportedNominalGlobalActor
            func stringResult() async -> String {
                await Task.yield()
                return "global"
            }

            func run() async -> String {
                await Task.detached {
                    await self.argumentBearing(12)
                }.value
                let text = await Task.detached {
                    await self.stringResult()
                }.value
                return await output(text)
            }

            @UnsupportedNominalGlobalActor
            func output(_ text: String) -> String {
                "\\(observation):\\(text)"
            }
        }

        final class UnsupportedWrappedGlobalActorProbe:
            @unchecked Sendable
        {
            var observation = ""

            @UnsupportedWrappedGlobalActor
            func update() async {
                await Task.yield()
                observation = "wrapped"
            }

            func run() async -> String {
                await Task.detached {
                    await self.update()
                }.value
                return await output()
            }

            @UnsupportedWrappedGlobalActor
            func output() -> String { observation }
        }

        final class UnsupportedInheritedIsolationProbe:
            @unchecked Sendable
        {
            var observation = ""

            func argumentBearing(_ value: Int) async {
                await Task.yield()
                observation += "\\(value):"
            }

            func stringResult() async -> String {
                await Task.yield()
                return "text"
            }

            nonisolated func explicitlyNonisolated() async {
                await Task.yield()
                observation += "explicit"
            }

            func run() async -> String {
                await Task.detached {
                    await self.argumentBearing(15)
                }.value
                let text = await Task.detached {
                    await self.stringResult()
                }.value
                await Task.detached {
                    await self.explicitlyNonisolated()
                }.value
                return "\\(observation):\\(text)"
            }
        }

        final class UnsupportedPhysicalCaptureShapeProbe:
            @unchecked Sendable
        {
            var observation = ""

            func update() async {
                await Task.yield()
                observation += "x"
            }

            func update(_ value: Int) async {
                await Task.yield()
                observation += "\\(value)"
            }

            func weakStringValue() async -> String {
                await Task.yield()
                return "weak"
            }

            func run() async -> String {
                await Task.detached { [unowned self] in
                    await self.update()
                }.value
                await Task.detached { [alias = self] in
                    await alias.update()
                }.value
                let marker = 1
                await Task.detached { [self, marker] in
                    await self.update()
                }.value
                await Task.detached { [self] () async -> Void in
                    await self.update()
                }.value
                let literal = await Task.detached { [self] in
                    7
                }.value
                await Task.detached { [weak self] in
                    await self?.update(2)
                }.value
                let weakString = await Task.detached { [weak self] in
                    await self?.weakStringValue()
                }.value ?? "missing"
                return "\\(observation):\\(marker):\\(literal):\\(weakString)"
            }
        }

        final class UnsupportedEnumGlobalActorProbe:
            @unchecked Sendable
        {
            var observation = ""

            @UnsupportedEnumGlobalActor
            func update() async {
                await Task.yield()
                observation = "enumerated"
            }

            func run() async -> String {
                await Task.detached {
                    await self.update()
                }.value
                return await output()
            }

            @UnsupportedEnumGlobalActor
            func output() -> String { observation }
        }

        @MainActor
        func probe() async -> String {
            let isolated = await IsolationProbe().run()
            let actor = await ActorProbe().run()
            let nominal = await UnsupportedNominalGlobalActorProbe().run()
            let wrapped = await UnsupportedWrappedGlobalActorProbe().run()
            let enumerated = await UnsupportedEnumGlobalActorProbe().run()
            let inherited = await UnsupportedInheritedIsolationProbe().run()
            let captures = await UnsupportedPhysicalCaptureShapeProbe().run()
            return "\\(isolated):\\(actor):\\(nominal):\\(wrapped):\\(enumerated):\\(inherited):\\(captures)"
        }

        await probe()
        """)

        #expect(value.stringValue
            == "nonisolated:7:5:3:text:true:actor:7:sync:true:FT:9:12:global:wrapped:enumerated:15:explicit:text:xxxx2:1:7:weak")
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
    func tryOptionalPhysicalReentryDoesNotSuppressInterpretedTrap()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        do {
            _ = try await interpreter.runAsync(source: """
            final class TryOptionalCrashingReentryProbe:
                @unchecked Sendable
            {
                func crash() async throws {
                    fatalError("contained try-optional physical source call")
                }

                func run() async -> Void? {
                    await Task.detached {
                        try? await self.crash()
                    }.value
                }
            }

            await TryOptionalCrashingReentryProbe().run()
            """)
            Issue.record("expected interpreted try-optional source-call trap")
        } catch let thrown as InterpretedThrow {
            let error = try #require(
                thrown.value.hostPayload as? RuntimeError)
            #expect(error.fatal)
            #expect(error.message.contains(
                "contained try-optional physical source call"))
        } catch {
            Issue.record("unexpected try-optional source-call failure: \(error)")
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

private actor DeferredWeakSourceCallPermitGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            precondition(releaseWaiter == nil)
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
