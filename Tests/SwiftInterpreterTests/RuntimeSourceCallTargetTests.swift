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
    func selectedSourceMemberCallStaysOnTheConfinedEvaluator()
        async throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/detached-source-member-call-target.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            executionMode: .parallel(parallelism))

        _ = try await interpreter.runAsync(source: source)
        let value = try await interpreter.runAsync(
            source: "await detachedSourceMemberCallTargetProbe()")

        #expect(value.stringValue == "target:member")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalSourceKernelExecutions == 0)
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
}
