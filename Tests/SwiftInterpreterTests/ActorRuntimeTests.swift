import Testing
@testable import SwiftInterpreter

@Suite("Actor runtime")
struct ActorRuntimeTests {
    @Test
    func globalActorIsolationResolvesCanonicalSharedIdentity() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
            @globalActor
            actor ProbeGlobalActor {
                static let shared = ProbeGlobalActor()
            }

            @ProbeGlobalActor
            func isolatedOperation() {}
            """)

        guard case .closure(let operation)? =
                interpreter.globals.lookup("isolatedOperation") else {
            Issue.record("missing collected global-actor operation")
            return
        }
        guard case .instance(let shared)? = try interpreter.staticMember(
            "shared",
            of: try #require(
                interpreter.globals.lookup("ProbeGlobalActor")?.typeSymbol)
        ) else {
            Issue.record("global actor shared did not produce an actor instance")
            return
        }
        let sharedID = try #require(shared.actorID)

        #expect(operation.globalActorAttributeCandidates.contains(
            "ProbeGlobalActor"))
        #expect(try interpreter.resolvedExecutor(for: operation)
            == .actor(sharedID))
        #expect(try interpreter.resolvedExecutor(for: operation)
            == .actor(sharedID))
        #expect(interpreter.concurrencyRuntime.actors[sharedID]?.instance
            === shared)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 1)
    }

    @Test
    func actorInstancesOwnDistinctRuntimeIdentitiesAndReleaseRecords() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
            actor Counter {}
            final class OrdinaryClass {}
            """)
        let actorSymbol = try #require(
            interpreter.globals.lookup("Counter")?.typeSymbol)
        let classSymbol = try #require(
            interpreter.globals.lookup("OrdinaryClass")?.typeSymbol)

        #expect(actorSymbol.isActor)
        #expect(actorSymbol.isClass)
        #expect(!classSymbol.isActor)

        var firstValue: RuntimeValue? = try interpreter.instantiateRoot(actorSymbol)
        var secondValue: RuntimeValue? = try interpreter.instantiateRoot(actorSymbol)
        var classValue: RuntimeValue? = try interpreter.instantiateRoot(classSymbol)
        var first: Instance? = try #require(Self.instance(from: firstValue))
        var second: Instance? = try #require(Self.instance(from: secondValue))
        let ordinaryClass = try #require(Self.instance(from: classValue))
        weak var releasedFirst = first
        weak var releasedSecond = second

        let firstID = try #require(first?.actorID)
        let secondID = try #require(second?.actorID)
        #expect(firstID != secondID)
        #expect(ordinaryClass.actorID == nil)
        #expect(interpreter.concurrencyRuntime.actors[firstID]?.instance === first)
        #expect(interpreter.concurrencyRuntime.actors[secondID]?.instance === second)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 2)

        firstValue = nil
        secondValue = nil
        classValue = nil
        first = nil
        second = nil

        #expect(releasedFirst == nil)
        #expect(releasedSecond == nil)
        #expect(interpreter.concurrencyRuntime.actors[firstID] == nil)
        #expect(interpreter.concurrencyRuntime.actors[secondID] == nil)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    private static func instance(from value: RuntimeValue?) -> Instance? {
        guard case .instance(let instance)? = value else { return nil }
        return instance
    }
}

private extension RuntimeValue {
    var typeSymbol: StructSymbol? {
        guard case .type(let symbol) = self else { return nil }
        return symbol
    }
}
