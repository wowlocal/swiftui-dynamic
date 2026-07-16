import Foundation
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
    func actorInitializationIsLexicallyNonisolatedThenUsesMailbox()
        async throws
    {
        let interpreter = Interpreter()
        var initializationIsolation: [String] = []
        var isolatedMethodActorID: RuntimeActorID?
        interpreter.globals.define(
            "parityCurrentIsolationKind",
            .hostFunction(HostFunction(
                name: "parityCurrentIsolationKind"
            ) { _, _ in
                let isolation = try interpreter.currentSourceIsolationValue()
                let kind = isolation.isNil ? "none" : "actor"
                initializationIsolation.append(kind)
                return .native(kind)
            }))
        interpreter.globals.define(
            "parityActorSegmentOwnership",
            .hostFunction(HostFunction(
                name: "parityActorSegmentOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                isolatedMethodActorID = actorID
                return .native("owned")
            }))

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("actor-initialization.swift")
        let declarations = try String(contentsOf: fixture, encoding: .utf8)
        let result = try await interpreter.runAsync(source:
            declarations + "\nawait actorInitializationProbe()\n")
        let symbol = try #require(
            interpreter.globals.lookup("ParityInitializationActor")?
                .typeSymbol)

        #expect(result.stringValue == "none:owned:5")
        #expect(initializationIsolation == ["none"])
        #expect(isolatedMethodActorID != nil)
        #expect(symbol.isActor)
        #expect(symbol.initializers.count == 1)
        #expect(symbol.initializers[0].signature.effectSpecifiers?
            .asyncSpecifier == nil)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test
    func actorHopPreservesTaskLocalStorageAcrossSuspension() async throws {
        struct Observation {
            let taskID: RuntimeTaskID
            let taskKind: RuntimeTaskKind
            let actorID: RuntimeActorID
            let taskLocalCount: Int
            let ownsActor: Bool
        }

        let interpreter = Interpreter()
        var observations: [Observation] = []
        var retainedStorage: RuntimeTaskLocalStorage?
        var recordStorageMatched = true
        interpreter.globals.define(
            "parityActorSegmentOwnership",
            .hostFunction(HostFunction(
                name: "parityActorSegmentOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      let record = interpreter.concurrencyRuntime
                        .records[taskID] else {
                    return .native("unowned")
                }
                let storage = interpreter.evaluationTaskContext.taskLocals
                retainedStorage = storage
                recordStorageMatched = recordStorageMatched
                    && record.taskLocals === storage
                let ownsActor = context.sourceExecutor.actorID == actorID
                    && interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID
                observations.append(Observation(
                    taskID: taskID,
                    taskKind: record.kind,
                    actorID: actorID,
                    taskLocalCount: storage.count,
                    ownsActor: ownsActor))
                return .native(ownsActor ? "owned" : "unowned")
            }))

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("actor-task-local-propagation.swift")
        let declarations = try String(contentsOf: fixture, encoding: .utf8)
        let result = try await interpreter.runAsync(source:
            declarations + "\nawait actorTaskLocalPropagationProbe()\n")
        let taskLocal = try #require(
            interpreter.enumSymbols["ParityActorTaskLocal"]?
                .taskLocalProperties["value"])

        #expect(result.stringValue
            == "default:owned|bound:owned|bound:owned>bound:owned|default:owned")
        #expect(observations.count == 5)
        #expect(Set(observations.map(\.taskID)).count == 1)
        #expect(Set(observations.map(\.actorID)).count == 1)
        #expect(observations.allSatisfy { $0.taskKind == .root })
        #expect(observations.map(\.taskLocalCount) == [0, 1, 1, 1, 0])
        #expect(observations.allSatisfy { $0.ownsActor })
        #expect(recordStorageMatched)
        #expect(taskLocal.cachedDefault?.stringValue == "default")
        #expect(retainedStorage?.isEmpty == true)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
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
    func actorSuspensionReleasesAndRestoresCompleteNestedSegment()
        async throws
    {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: "actor SuspensionProbe {}")
        let actorSymbol = try #require(
            interpreter.globals.lookup("SuspensionProbe")?.typeSymbol)
        var actorValue: RuntimeValue? = try interpreter.instantiateRoot(
            actorSymbol)
        var actor: Instance? = try #require(Self.instance(from: actorValue))
        let actorID = try #require(actor?.actorID)
        let runtime = interpreter.concurrencyRuntime
        let task = runtime.createTask(
            sessionID: runtime.createSession(),
            kind: .unstructured,
            parent: nil,
            priority: .medium,
            executorPreference: .actor(actorID),
            taskLocals: RuntimeTaskLocalStorage(),
            name: "suspended-owner")
        #expect(runtime.begin(task))

        let outer = try await runtime.acquireActorExecutor(
            actorID, for: task.id)
        let nested = try await runtime.acquireActorExecutor(
            actorID, for: task.id)
        let suspension = runtime.beginTaskSuspension(
            task.id, for: .yielding)

        #expect(task.state == .waiting)
        #expect(task.suspension == .yielding)
        #expect(task.suspensionHistory == [.yielding])
        #expect(runtime.actors[actorID]?.executorOwnerTaskID == nil)

        await runtime.endTaskSuspension(suspension)
        #expect(task.state == .running)
        #expect(task.suspension == nil)
        #expect(runtime.actors[actorID]?.executorOwnerTaskID == task.id)

        runtime.releaseActorExecutor(nested)
        #expect(runtime.actors[actorID]?.executorOwnerTaskID == task.id)
        runtime.releaseActorExecutor(outer)
        #expect(runtime.actors[actorID]?.executorOwnerTaskID == nil)

        runtime.succeed(task, with: .void)
        runtime.release(task.id)
        actorValue = nil
        actor = nil
        #expect(runtime.activeRecordCount == 0)
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

    @Test
    func actorComputedPropertyAcquiresExecutorAndRejectsUnawaitedEntry()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectComputedOwnership",
            .hostFunction(HostFunction(
                name: "inspectComputedOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let result = try await interpreter.runAsync(source: """
            actor ComputedProbe {
                var stored = 0

                var next: String {
                    let ownership = inspectComputedOwnership(self)
                    guard ownership == "owned" else { return ownership }
                    stored += 1
                    return ownership + ":" + String(stored)
                }

                nonisolated var label: String { "free" }
            }

            func runComputedProbe() async -> String {
                let probe = ComputedProbe()
                let first = await probe.next
                let second = await probe.next
                return first + "|" + second + "|" + probe.label
            }

            await runComputedProbe()
            """)
        let symbol = try #require(
            interpreter.globals.lookup("ComputedProbe")?.typeSymbol)

        #expect(result.stringValue == "owned:1|owned:2|free")
        #expect(symbol.computedProperties["next"]?.isNonisolated == false)
        #expect(symbol.computedProperties["label"]?.isNonisolated == true)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor ComputedProbe {
                    var value: Int { 1 }
                }
                let probe = ComputedProbe()
                probe.value
                """)
            Issue.record(
                "actor computed property entered synchronously without ownership")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "cross-actor synchronous call requires an awaited "
                    + "actor-executor entry"))
        }
    }

    @Test
    func crossActorComputedPropertyFailureRestoresCallerAndReleasesTarget()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectComputedFailureOwnership",
            .hostFunction(HostFunction(
                name: "inspectComputedFailureOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let result = try await interpreter.runAsync(source: """
            enum ComputedFailure: Error { case boom }

            actor ComputedFailureTarget {
                var stored = 0
                var failureOwnership = "unset"

                var failingValue: Int {
                    get throws {
                        failureOwnership = inspectComputedFailureOwnership(self)
                        stored += 1
                        throw ComputedFailure.boom
                    }
                }

                func recover() -> String {
                    let recoveryOwnership = inspectComputedFailureOwnership(self)
                    stored += 1
                    return failureOwnership + ":" + recoveryOwnership
                        + ":" + String(stored)
                }
            }

            actor ComputedFailureCaller {
                func run(_ target: ComputedFailureTarget) async -> String {
                    let before = inspectComputedFailureOwnership(self)
                    var outcome = "missed"
                    do {
                        _ = try await target.failingValue
                    } catch ComputedFailure.boom {
                        outcome = "caught"
                    } catch {
                        outcome = "other"
                    }
                    let afterFailure = inspectComputedFailureOwnership(self)
                    let recovered = await target.recover()
                    let afterRecovery = inspectComputedFailureOwnership(self)
                    return before + "|" + outcome + "|" + afterFailure
                        + "|" + recovered + "|" + afterRecovery
                }
            }

            func runComputedFailureProbe() async -> String {
                let target = ComputedFailureTarget()
                let caller = ComputedFailureCaller()
                return await caller.run(target)
            }

            await runComputedFailureProbe()
            """)

        #expect(result.stringValue
            == "owned|caught|owned|owned:owned:2|owned")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func asyncActorComputedPropertyCancellationRestoresCallerAndReleasesTarget()
        async throws
    {
        let interpreter = Interpreter()
        var accessorSuspended = false
        var accessorMayResume = false
        interpreter.globals.define(
            "inspectComputedCancellationOwnership",
            .hostFunction(HostFunction(
                name: "inspectComputedCancellationOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))
        interpreter.globals.define(
            "suspendComputedCancellationMessage",
            .hostFunction(HostFunction(
                name: "suspendComputedCancellationMessage",
                asyncInvoke: { _, _ in
                    accessorSuspended = true
                    while !accessorMayResume { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "awaitComputedCancellationSuspension",
            .hostFunction(HostFunction(
                name: "awaitComputedCancellationSuspension",
                asyncInvoke: { _, _ in
                    while !accessorSuspended { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "resumeComputedCancellationMessage",
            .hostFunction(HostFunction(
                name: "resumeComputedCancellationMessage",
                asyncInvoke: { _, _ in
                    accessorMayResume = true
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
            actor ComputedCancellationTarget {
                var stored = 0
                var entryOwnership = "unset"
                var resumeOwnership = "unset"

                var cancellingValue: Int {
                    get async throws {
                        entryOwnership = inspectComputedCancellationOwnership(self)
                        stored += 1
                        await suspendComputedCancellationMessage()
                        resumeOwnership = inspectComputedCancellationOwnership(self)
                        try Task.checkCancellation()
                        return stored
                    }
                }

                func recover() -> String {
                    let recoveryOwnership =
                        inspectComputedCancellationOwnership(self)
                    stored += 1
                    return entryOwnership + ":" + resumeOwnership
                        + ":" + recoveryOwnership + ":" + String(stored)
                }
            }

            actor ComputedCancellationCaller {
                func run(_ target: ComputedCancellationTarget) async -> String {
                    let before = inspectComputedCancellationOwnership(self)
                    var outcome = "missed"
                    do {
                        _ = try await target.cancellingValue
                    } catch is CancellationError {
                        outcome = "cancelled"
                    } catch {
                        outcome = "other"
                    }
                    let afterCancellation =
                        inspectComputedCancellationOwnership(self)
                    let recovered = await target.recover()
                    let afterRecovery =
                        inspectComputedCancellationOwnership(self)
                    return before + "|" + outcome + "|" + afterCancellation
                        + "|" + recovered + "|" + afterRecovery
                }
            }

            func runComputedCancellationProbe() async -> String {
                let target = ComputedCancellationTarget()
                let caller = ComputedCancellationCaller()
                let task = Task { await caller.run(target) }
                await awaitComputedCancellationSuspension()
                task.cancel()
                await resumeComputedCancellationMessage()
                return await task.value
            }

            await runComputedCancellationProbe()
            """)
        let symbol = try #require(
            interpreter.globals.lookup("ComputedCancellationTarget")?
                .typeSymbol)
        let getter = try #require(
            symbol.computedProperties["cancellingValue"])

        #expect(result.stringValue
            == "owned|cancelled|owned|owned:owned:owned:2|owned")
        #expect(getter.isAsync)
        #expect(getter.isThrowing)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor AsyncComputedProbe {
                    var value: Int { get async { 1 } }
                }
                let probe = AsyncComputedProbe()
                probe.value
                """)
            Issue.record(
                "async actor computed property executed through eager entry")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "requires an awaited suspending entry"))
        }
    }

    @Test
    func asyncActorComputedPropertySuccessAndSourceErrorBalanceExecutors()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectComputedExitOwnership",
            .hostFunction(HostFunction(
                name: "inspectComputedExitOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))
        interpreter.globals.define(
            "yieldComputedExit",
            .hostFunction(HostFunction(
                name: "yieldComputedExit",
                asyncInvoke: { _, _ in
                    await Task.yield()
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
            enum ComputedExitFailure: Error {
                case boom
            }

            actor ComputedExitTarget {
                let shouldThrow: Bool
                var stored = 0
                var entryOwnership = "unset"
                var resumeOwnership = "unset"

                init(shouldThrow: Bool) {
                    self.shouldThrow = shouldThrow
                }

                var value: Int {
                    get async throws {
                        entryOwnership = inspectComputedExitOwnership(self)
                        stored += 1
                        await yieldComputedExit()
                        resumeOwnership = inspectComputedExitOwnership(self)
                        if shouldThrow { throw ComputedExitFailure.boom }
                        return stored
                    }
                }

                func snapshot() -> String {
                    entryOwnership + ":" + resumeOwnership + ":"
                        + inspectComputedExitOwnership(self) + ":"
                        + String(stored)
                }
            }

            actor ComputedExitCaller {
                func succeed(_ target: ComputedExitTarget) async -> String {
                    do {
                        let value = try await target.value
                        return "value:" + String(value) + ":"
                            + inspectComputedExitOwnership(self)
                    } catch {
                        return "unexpected"
                    }
                }

                func fail(_ target: ComputedExitTarget) async -> String {
                    var outcome = "missed"
                    do {
                        _ = try await target.value
                    } catch ComputedExitFailure.boom {
                        outcome = "caught"
                    } catch {
                        outcome = "other"
                    }
                    return outcome + ":"
                        + inspectComputedExitOwnership(self)
                }
            }

            func runComputedExitProbe() async -> String {
                let successTarget = ComputedExitTarget(shouldThrow: false)
                let failureTarget = ComputedExitTarget(shouldThrow: true)
                let caller = ComputedExitCaller()
                let success = await caller.succeed(successTarget)
                let successSnapshot = await successTarget.snapshot()
                let failure = await caller.fail(failureTarget)
                let failureSnapshot = await failureTarget.snapshot()
                return success + "|" + successSnapshot + "||"
                    + failure + "|" + failureSnapshot
            }

            await runComputedExitProbe()
            """)
        let symbol = try #require(
            interpreter.globals.lookup("ComputedExitTarget")?.typeSymbol)
        let getter = try #require(symbol.computedProperties["value"])

        #expect(result.stringValue
            == "value:1:owned|owned:owned:owned:1"
                + "||caught:owned|owned:owned:owned:1")
        #expect(getter.isAsync)
        #expect(getter.isThrowing)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func actorComputedSetterRequiresOwnedSynchronousEntry() async throws {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectComputedSetterOwnership",
            .hostFunction(HostFunction(
                name: "inspectComputedSetterOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let result = try await interpreter.runAsync(source: """
            actor SetterProbe {
                var stored = 0
                var setterOwnership = "unset"

                var value: Int {
                    get { stored }
                    set {
                        setterOwnership = inspectComputedSetterOwnership(self)
                        stored = newValue
                    }
                }

                func assign(_ newValue: Int) -> String {
                    value = newValue
                    return setterOwnership + ":" + String(stored)
                }
            }

            func runSetterProbe() async -> String {
                let probe = SetterProbe()
                return await probe.assign(7)
            }

            await runSetterProbe()
            """)

        #expect(result.stringValue == "owned:7")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor SetterProbe {
                    var value: Int {
                        get { 0 }
                        set {}
                    }
                }
                let probe = SetterProbe()
                probe.value = 1
                """)
            Issue.record(
                "actor computed setter executed without executor ownership")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "cross-actor synchronous call requires an awaited "
                    + "actor-executor entry"))
        }
    }

    @Test
    func actorSubscriptGetterAcquiresExecutorAndRejectsUnawaitedEntry()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectSubscriptOwnership",
            .hostFunction(HostFunction(
                name: "inspectSubscriptOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let result = try await interpreter.runAsync(source: """
            actor SubscriptProbe {
                var stored = 0

                subscript(_ increment: Int) -> String {
                    let ownership = inspectSubscriptOwnership(self)
                    guard ownership == "owned" else { return ownership }
                    stored += increment
                    return ownership + ":" + String(stored)
                }

                nonisolated subscript(direct first: Int, _ second: Int) -> String {
                    inspectSubscriptOwnership(self)
                }

                func current() -> Int { stored }
            }

            func runSubscriptProbe() async -> String {
                let probe = SubscriptProbe()
                let isolated = await probe[2]
                let direct = probe[direct: 0, 0]
                let final = await probe.current()
                return isolated + "|" + direct + "|" + String(final)
            }

            await runSubscriptProbe()
            """)
        let symbol = try #require(
            interpreter.globals.lookup("SubscriptProbe")?.typeSymbol)
        let isolated = try #require(symbol.subscripts.first {
            $0.parameters.count == 1
        })
        let nonisolated = try #require(symbol.subscripts.first {
            $0.parameters.count == 2
        })

        #expect(result.stringValue == "owned:2|unowned|2")
        #expect(!isolated.isNonisolated)
        #expect(nonisolated.isNonisolated)
        #expect(isolated.declarationID != nil)
        #expect(nonisolated.declarationID != nil)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor SubscriptProbe {
                    subscript(_ index: Int) -> Int { index }
                }
                let probe = SubscriptProbe()
                probe[0]
                """)
            Issue.record(
                "actor subscript getter entered synchronously without ownership")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "cross-actor synchronous call requires an awaited "
                    + "actor-executor entry"))
        }
    }

    @Test
    func asyncActorSubscriptCancellationRestoresCallerAndReleasesTarget()
        async throws
    {
        let interpreter = Interpreter()
        var accessorSuspended = false
        var accessorMayResume = false
        interpreter.globals.define(
            "inspectSubscriptCancellationOwnership",
            .hostFunction(HostFunction(
                name: "inspectSubscriptCancellationOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))
        interpreter.globals.define(
            "suspendSubscriptCancellationMessage",
            .hostFunction(HostFunction(
                name: "suspendSubscriptCancellationMessage",
                asyncInvoke: { _, _ in
                    accessorSuspended = true
                    while !accessorMayResume { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "awaitSubscriptCancellationSuspension",
            .hostFunction(HostFunction(
                name: "awaitSubscriptCancellationSuspension",
                asyncInvoke: { _, _ in
                    while !accessorSuspended { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "resumeSubscriptCancellationMessage",
            .hostFunction(HostFunction(
                name: "resumeSubscriptCancellationMessage",
                asyncInvoke: { _, _ in
                    accessorMayResume = true
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
            actor SubscriptCancellationTarget {
                var stored = 0
                var entryOwnership = "unset"
                var resumeOwnership = "unset"

                subscript(_ increment: Int) -> Int {
                    get async throws {
                        entryOwnership =
                            inspectSubscriptCancellationOwnership(self)
                        stored += increment
                        await suspendSubscriptCancellationMessage()
                        resumeOwnership =
                            inspectSubscriptCancellationOwnership(self)
                        try Task.checkCancellation()
                        return stored
                    }
                }

                func recover() -> String {
                    let recoveryOwnership =
                        inspectSubscriptCancellationOwnership(self)
                    stored += 1
                    return entryOwnership + ":" + resumeOwnership
                        + ":" + recoveryOwnership + ":" + String(stored)
                }
            }

            actor SubscriptCancellationCaller {
                func run(_ target: SubscriptCancellationTarget) async -> String {
                    let before = inspectSubscriptCancellationOwnership(self)
                    var outcome = "missed"
                    do {
                        _ = try await target[1]
                    } catch is CancellationError {
                        outcome = "cancelled"
                    } catch {
                        outcome = "other"
                    }
                    let afterCancellation =
                        inspectSubscriptCancellationOwnership(self)
                    let recovered = await target.recover()
                    let afterRecovery =
                        inspectSubscriptCancellationOwnership(self)
                    return before + "|" + outcome + "|" + afterCancellation
                        + "|" + recovered + "|" + afterRecovery
                }
            }

            func runSubscriptCancellationProbe() async -> String {
                let target = SubscriptCancellationTarget()
                let caller = SubscriptCancellationCaller()
                let task = Task { await caller.run(target) }
                await awaitSubscriptCancellationSuspension()
                task.cancel()
                await resumeSubscriptCancellationMessage()
                return await task.value
            }

            await runSubscriptCancellationProbe()
            """)
        let symbol = try #require(
            interpreter.globals.lookup("SubscriptCancellationTarget")?
                .typeSymbol)
        let getter = try #require(symbol.subscripts.first)

        #expect(result.stringValue
            == "owned|cancelled|owned|owned:owned:owned:2|owned")
        #expect(getter.isAsync)
        #expect(getter.isThrowing)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor AsyncSubscriptProbe {
                    subscript(_ index: Int) -> Int {
                        get async { index }
                    }
                }
                let probe = AsyncSubscriptProbe()
                probe[0]
                """)
            Issue.record(
                "async actor subscript executed through eager entry")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "requires an awaited suspending entry"))
        }
    }

    @Test
    func asyncActorSubscriptSuccessAndSourceErrorBalanceExecutors()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectSubscriptExitOwnership",
            .hostFunction(HostFunction(
                name: "inspectSubscriptExitOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))
        interpreter.globals.define(
            "yieldSubscriptExit",
            .hostFunction(HostFunction(
                name: "yieldSubscriptExit",
                asyncInvoke: { _, _ in
                    await Task.yield()
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
            enum SubscriptExitFailure: Error {
                case boom
            }

            actor SubscriptExitTarget {
                var stored = 0
                var entryOwnership = "unset"
                var resumeOwnership = "unset"

                subscript(_ shouldThrow: Bool) -> Int {
                    get async throws {
                        entryOwnership = inspectSubscriptExitOwnership(self)
                        stored += 1
                        await yieldSubscriptExit()
                        resumeOwnership = inspectSubscriptExitOwnership(self)
                        if shouldThrow { throw SubscriptExitFailure.boom }
                        return stored
                    }
                }

                func snapshot() -> String {
                    entryOwnership + ":" + resumeOwnership + ":"
                        + inspectSubscriptExitOwnership(self) + ":"
                        + String(stored)
                }
            }

            actor SubscriptExitCaller {
                func succeed(_ target: SubscriptExitTarget) async -> String {
                    do {
                        let value = try await target[false]
                        return "value:" + String(value) + ":"
                            + inspectSubscriptExitOwnership(self)
                    } catch {
                        return "unexpected"
                    }
                }

                func fail(_ target: SubscriptExitTarget) async -> String {
                    var outcome = "missed"
                    do {
                        _ = try await target[true]
                    } catch SubscriptExitFailure.boom {
                        outcome = "caught"
                    } catch {
                        outcome = "other"
                    }
                    return outcome + ":"
                        + inspectSubscriptExitOwnership(self)
                }
            }

            func runSubscriptExitProbe() async -> String {
                let target = SubscriptExitTarget()
                let caller = SubscriptExitCaller()
                let success = await caller.succeed(target)
                let failure = await caller.fail(target)
                let snapshot = await target.snapshot()
                return success + "|" + failure + "|" + snapshot
            }

            await runSubscriptExitProbe()
            """)
        let symbol = try #require(
            interpreter.globals.lookup("SubscriptExitTarget")?.typeSymbol)
        let getter = try #require(symbol.subscripts.first)

        #expect(result.stringValue
            == "value:1:owned|caught:owned|owned:owned:owned:2")
        #expect(getter.isAsync)
        #expect(getter.isThrowing)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func actorSubscriptSetterRequiresOwnedSynchronousEntry() async throws {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectSubscriptSetterOwnership",
            .hostFunction(HostFunction(
                name: "inspectSubscriptSetterOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let result = try await interpreter.runAsync(source: """
            actor SetterProbe {
                var stored = 0
                var setterOwnership = "unset"

                subscript(_ index: Int) -> Int {
                    get { stored + index }
                    set {
                        setterOwnership = inspectSubscriptSetterOwnership(self)
                        stored = newValue
                    }
                }

                func assign(_ newValue: Int) -> String {
                    self[0] = newValue
                    return setterOwnership + ":" + String(stored)
                }
            }

            func runSetterProbe() async -> String {
                let probe = SetterProbe()
                return await probe.assign(7)
            }

            await runSetterProbe()
            """)

        #expect(result.stringValue == "owned:7")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor SetterProbe {
                    subscript(_ index: Int) -> Int {
                        get { index }
                        set {}
                    }
                }
                let probe = SetterProbe()
                probe[0] = 1
                """)
            Issue.record(
                "actor subscript setter executed without executor ownership")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "cross-actor synchronous call requires an awaited "
                    + "actor-executor entry"))
        }
    }

    @Test
    func isolatedParameterSelectsArgumentActorAndRejectsUnawaitedEntry()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectIsolatedParameterOwnership",
            .hostFunction(HostFunction(
                name: "inspectIsolatedParameterOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let result = try await interpreter.runAsync(source: """
            actor IsolatedParameterProbe {
                var stored = 0

                func addLocally(_ amount: Int) -> String {
                    addToIsolatedParameter(self, by: amount)
                }

                func current() -> Int { stored }
            }

            func addToIsolatedParameter(
                _ probe: isolated IsolatedParameterProbe,
                by amount: Int
            ) -> String {
                let ownership = inspectIsolatedParameterOwnership(probe)
                guard ownership == "owned" else { return ownership }
                probe.stored += amount
                return ownership + ":" + String(probe.stored)
            }

            func runIsolatedParameterProbe() async -> String {
                let probe = IsolatedParameterProbe()
                let first = await addToIsolatedParameter(probe, by: 2)
                let second = await probe.addLocally(3)
                let final = await probe.current()
                return first + "|" + second + "|" + String(final)
            }

            await runIsolatedParameterProbe()
            """)
        guard case .closure(let operation)? = interpreter.globals.lookup(
            "addToIsolatedParameter") else {
            Issue.record("missing isolated-parameter operation")
            return
        }

        #expect(result.stringValue == "owned:2|owned:5|5")
        #expect(operation.parameters.map(\.isIsolated) == [true, false])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)

        do {
            _ = try await Interpreter().runAsync(source: """
                actor IsolatedParameterProbe {
                    var stored = 0
                }
                func readIsolatedParameter(
                    _ probe: isolated IsolatedParameterProbe
                ) -> Int {
                    probe.stored
                }
                let probe = IsolatedParameterProbe()
                readIsolatedParameter(probe)
                """)
            Issue.record(
                "isolated parameter entered synchronously without ownership")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.message.contains(
                "cross-actor synchronous call requires an awaited "
                    + "actor-executor entry"))
        }
    }

    @Test
    func defaultedOptionalIsolatedParameterUsesCallerLexicalIsolationAndNil()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "parityActorSegmentOwnership",
            .hostFunction(HostFunction(
                name: "parityActorSegmentOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))
        interpreter.globals.define(
            "parityCurrentIsolationKind",
            .hostFunction(HostFunction(
                name: "parityCurrentIsolationKind"
            ) { _, context in
                .native(context.sourceExecutor.actorID == nil
                    ? "none" : "actor")
            }))

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(
                "actor-isolated-parameter-defaults.swift")
        let declarations = try String(
            contentsOf: fixture,
            encoding: .utf8)
        let result = try await interpreter.runAsync(source:
            declarations + "\nawait actorIsolatedParameterDefaultsProbe()\n")
        guard case .closure(let operation)? = interpreter.globals.lookup(
            "defaultedIsolationObservation") else {
            Issue.record("missing defaulted isolated-parameter operation")
            return
        }

        #expect(result.stringValue
            == "owned:actor|owned:actor|unowned:none|unowned:none")
        #expect(operation.parameters.map(\.isIsolated) == [false, true])
        #expect(operation.parameters[1].defaultValue?.trimmedDescription
            == "#isolation")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test
    func arbitraryGlobalActorDefaultsUseCanonicalSharedCapabilities()
        async throws
    {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "parityCurrentIsolationMatches",
            .hostFunction(HostFunction(
                name: "parityCurrentIsolationMatches"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let expectedID = expected.actorID,
                      let actualID = context.sourceExecutor.actorID else {
                    return .native("none")
                }
                return .native(actualID == expectedID ? "same" : "other")
            }))
        interpreter.globals.define(
            "parityActorSegmentOwnership",
            .hostFunction(HostFunction(
                name: "parityActorSegmentOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(
                "actor-arbitrary-global-actor-isolation.swift")
        let declarations = try String(
            contentsOf: fixture,
            encoding: .utf8)
        let result = try await interpreter.runAsync(source:
            declarations + "\nawait arbitraryGlobalActorIsolationProbe()\n")
        let globalActor = try #require(
            interpreter.globals.lookup("ParityArbitraryGlobalActor")?
                .typeSymbol)
        guard case .enumType(let enumGlobalActor)? =
                interpreter.globals.lookup("ParityEnumGlobalActor") else {
            Issue.record("missing enum-backed global actor")
            return
        }
        guard case .instance(let shared)? = try interpreter.staticMember(
            "shared", of: globalActor) else {
            Issue.record("struct-backed global actor lost its shared actor")
            return
        }
        guard case .instance(let enumShared)? = try interpreter.staticMember(
            "shared", of: enumGlobalActor) else {
            Issue.record("enum-backed global actor lost its shared actor")
            return
        }
        let sharedID = try #require(shared.actorID)
        let enumSharedID = try #require(enumShared.actorID)
        guard case .closure(let entry)? = interpreter.globals.lookup(
            "parityArbitraryGlobalActorEntry") else {
            Issue.record("missing arbitrary-global-actor entry")
            return
        }
        guard case .closure(let enumEntry)? = interpreter.globals.lookup(
            "parityEnumGlobalActorEntry") else {
            Issue.record("missing enum-global-actor entry")
            return
        }
        guard case .closure(let defaulted)? = interpreter.globals.lookup(
            "parityArbitraryGlobalActorDefault") else {
            Issue.record("missing defaulted isolation observer")
            return
        }

        #expect(result.stringValue
            == "same:owned:same|same:owned:same")
        #expect(!globalActor.isActor)
        #expect(globalActor.attributeNames.contains("globalActor"))
        #expect(enumGlobalActor.attributeNames.contains("globalActor"))
        #expect(shared.symbol.isActor)
        #expect(enumShared.symbol.isActor)
        #expect(entry.globalActorAttributeCandidates.contains(
            "ParityArbitraryGlobalActor"))
        #expect(enumEntry.globalActorAttributeCandidates.contains(
            "ParityEnumGlobalActor"))
        #expect(try interpreter.resolvedExecutor(for: entry)
            == .actor(sharedID))
        #expect(try interpreter.resolvedExecutor(for: enumEntry)
            == .actor(enumSharedID))
        #expect(defaulted.parameters[1].isIsolated)
        #expect(defaulted.parameters[1].defaultValue?.trimmedDescription
            == "#isolation")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 2)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test
    func crossActorFailureRestoresCallerAndReleasesCallee() async throws {
        let interpreter = Interpreter()
        interpreter.globals.define(
            "inspectFailureOwnership",
            .hostFunction(HostFunction(
                name: "inspectFailureOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))

        let result = try await interpreter.runAsync(source: """
            enum HopFailure: Error { case boom }

            actor FailureTarget {
                var stored = 0
                var failureOwnership = "unset"

                func fail() throws {
                    failureOwnership = inspectFailureOwnership(self)
                    stored += 1
                    throw HopFailure.boom
                }

                func recover() -> String {
                    let recoveryOwnership = inspectFailureOwnership(self)
                    stored += 1
                    return failureOwnership + ":" + recoveryOwnership
                        + ":" + String(stored)
                }
            }

            actor FailureCaller {
                func run(_ target: FailureTarget) async -> String {
                    let before = inspectFailureOwnership(self)
                    var outcome = "missed"
                    do {
                        try await target.fail()
                    } catch {
                        outcome = "caught"
                    }
                    let afterFailure = inspectFailureOwnership(self)
                    let recovered = await target.recover()
                    let afterRecovery = inspectFailureOwnership(self)
                    return before + "|" + outcome + "|" + afterFailure
                        + "|" + recovered + "|" + afterRecovery
                }
            }

            func runFailureProbe() async -> String {
                let target = FailureTarget()
                let caller = FailureCaller()
                return await caller.run(target)
            }

            await runFailureProbe()
            """)

        #expect(result.stringValue
            == "owned|caught|owned|owned:owned:2|owned")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeActorCount == 0)
    }

    @Test
    func crossActorCancellationRestoresCallerAndReleasesCallee() async throws {
        let interpreter = Interpreter()
        var actorMessageSuspended = false
        var actorMessageMayResume = false
        interpreter.globals.define(
            "inspectCancellationOwnership",
            .hostFunction(HostFunction(
                name: "inspectCancellationOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID,
                      interpreter.concurrencyRuntime.actors[actorID]?
                        .executorOwnerTaskID == taskID else {
                    return .native("unowned")
                }
                return .native("owned")
            }))
        interpreter.globals.define(
            "suspendCancellationMessage",
            .hostFunction(HostFunction(
                name: "suspendCancellationMessage",
                asyncInvoke: { _, _ in
                    actorMessageSuspended = true
                    while !actorMessageMayResume { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "awaitCancellationMessageSuspension",
            .hostFunction(HostFunction(
                name: "awaitCancellationMessageSuspension",
                asyncInvoke: { _, _ in
                    while !actorMessageSuspended { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "resumeCancellationMessage",
            .hostFunction(HostFunction(
                name: "resumeCancellationMessage",
                asyncInvoke: { _, _ in
                    actorMessageMayResume = true
                    return .void
                })))

        let result = try await interpreter.runAsync(source: """
            actor CancellationTarget {
                var stored = 0
                var entryOwnership = "unset"
                var resumeOwnership = "unset"

                func cancellationPoint() async throws {
                    entryOwnership = inspectCancellationOwnership(self)
                    stored += 1
                    await suspendCancellationMessage()
                    resumeOwnership = inspectCancellationOwnership(self)
                    try Task.checkCancellation()
                }

                func recover() -> String {
                    let recoveryOwnership = inspectCancellationOwnership(self)
                    stored += 1
                    return entryOwnership + ":" + resumeOwnership
                        + ":" + recoveryOwnership + ":" + String(stored)
                }
            }

            actor CancellationCaller {
                func run(_ target: CancellationTarget) async -> String {
                    let before = inspectCancellationOwnership(self)
                    var outcome = "missed"
                    do {
                        try await target.cancellationPoint()
                    } catch is CancellationError {
                        outcome = "cancelled"
                    } catch {
                        outcome = "other"
                    }
                    let afterCancellation = inspectCancellationOwnership(self)
                    let recovered = await target.recover()
                    let afterRecovery = inspectCancellationOwnership(self)
                    return before + "|" + outcome + "|" + afterCancellation
                        + "|" + recovered + "|" + afterRecovery
                }
            }

            func runCancellationProbe() async -> String {
                let target = CancellationTarget()
                let caller = CancellationCaller()
                let task = Task { await caller.run(target) }
                await awaitCancellationMessageSuspension()
                task.cancel()
                await resumeCancellationMessage()
                return await task.value
            }

            await runCancellationProbe()
            """)

        #expect(result.stringValue
            == "owned|cancelled|owned|owned:owned:owned:2|owned")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
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
