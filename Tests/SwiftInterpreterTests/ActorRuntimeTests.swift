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

    @Test
    func actorMailboxSuspendsHandsOffAndReleasesRuntimeEdges() async throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: "actor MailboxProbe {}")
        let actorSymbol = try #require(
            interpreter.globals.lookup("MailboxProbe")?.typeSymbol)
        var actorValue: RuntimeValue? = try interpreter.instantiateRoot(
            actorSymbol)
        var actor: Instance? = try #require(Self.instance(from: actorValue))
        let actorID = try #require(actor?.actorID)
        let runtime = interpreter.concurrencyRuntime
        let session = runtime.createSession()
        let first = runtime.createTask(
            sessionID: session,
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .actor(actorID),
            taskLocals: RuntimeTaskLocalStorage(),
            name: "first")
        let second = runtime.createTask(
            sessionID: session,
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .actor(actorID),
            taskLocals: RuntimeTaskLocalStorage(),
            name: "second")
        #expect(runtime.begin(first))
        #expect(runtime.begin(second))

        let firstLease = try await runtime.acquireActorExecutor(
            actorID, for: first.id)
        let secondAcquisition = Task { @MainActor in
            try await runtime.acquireActorExecutor(actorID, for: second.id)
        }
        for _ in 0..<1_000 {
            if runtime.actors[actorID]?.mailboxTaskIDs == [second.id] {
                break
            }
            await Task.yield()
        }

        #expect(runtime.actors[actorID]?.executorOwnerTaskID == first.id)
        #expect(runtime.actors[actorID]?.mailboxTaskIDs == [second.id])
        #expect(second.state == .waiting)
        #expect(second.suspension == .waitingForActor(actorID))

        runtime.releaseActorExecutor(firstLease)
        let secondLease = try await secondAcquisition.value
        #expect(runtime.actors[actorID]?.executorOwnerTaskID == second.id)
        #expect(runtime.actors[actorID]?.mailboxTaskIDs.isEmpty == true)
        #expect(second.state == .running)
        #expect(second.suspension == nil)
        #expect(second.suspensionHistory == [.waitingForActor(actorID)])

        runtime.releaseActorExecutor(secondLease)
        runtime.succeed(first, with: .void)
        runtime.succeed(second, with: .void)
        runtime.release(first.id)
        runtime.release(second.id)
        #expect(runtime.actors[actorID]?.executorOwnerTaskID == nil)
        #expect(runtime.activeRecordCount == 0)

        actorValue = nil
        actor = nil
        #expect(runtime.activeActorCount == 0)
    }

    @Test
    func actorMutableStorageRequiresOwnershipWhileAllowedStorageRemainsReadable()
        async throws
    {
        let allowedInterpreter = Interpreter()
        let allowed = try await allowedInterpreter.runAsync(source: """
            actor StorageProbe {
                var mutable = 1
                let immutable = 2
                nonisolated(unsafe) var unsafeValue = 3
            }
            let probe = StorageProbe()
            String(probe.immutable) + ":" + String(probe.unsafeValue)
            """)
        let symbol = try #require(
            allowedInterpreter.globals.lookup("StorageProbe")?.typeSymbol)

        #expect(allowed.stringValue == "2:3")
        #expect(symbol.storedProperty(named: "mutable")?
            .requiresActorExecutor == true)
        #expect(symbol.storedProperty(named: "immutable")?
            .requiresActorExecutor == false)
        #expect(symbol.storedProperty(named: "unsafeValue")?
            .requiresActorExecutor == false)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor StorageProbe {
                    var mutable = 1
                }
                let probe = StorageProbe()
                probe.mutable
                """)
            Issue.record(
                "mutable actor storage was readable without executor ownership")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "StorageProbe.mutable' accessed without owning its executor"))
        }
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
