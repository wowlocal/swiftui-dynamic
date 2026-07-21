import Foundation
import Testing
@testable import SwiftInterpreter

private final class CheckedContinuationProducerGate {
    var entered = false
    var isOpen = false
}

@Suite("Checked continuation runtime")
struct CheckedContinuationRuntimeTests {
    @Test func detachedProducerResumesValueAndClosesRuntimeRecord()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/checked-continuation-value-resume.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedContinuationValueResumeProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "41")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount >= 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func throwingValueAndSourceErrorShareRecordCleanup()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-throwing-continuation-value-error.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedThrowingContinuationValueErrorProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "value:23|error:failed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func doubleResumeIsFatalAcrossCheckedFormsAndCleansUp()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cases = [
            (
                fixture: "checked-continuation-double-resume.swift",
                entry: "await checkedContinuationDoubleResumeProbe()"
            ),
            (
                fixture: "checked-throwing-continuation-double-resume.swift",
                entry: "await checkedThrowingContinuationDoubleResumeProbe()"
            ),
        ]

        for item in cases {
            let fixture = packageRoot.appendingPathComponent(
                "Tests/ConcurrencyParity/Fixtures/" + item.fixture)
            let source = try String(contentsOf: fixture, encoding: .utf8)
                + "\n\(item.entry)\n"
            let interpreter = Interpreter()

            do {
                _ = try await interpreter.runAsync(source: source)
                Issue.record("double resume did not remain a fatal invariant")
            } catch let error as RuntimeError {
                #expect(error.fatal)
                #expect(error.message.contains("checked continuation"))
                #expect(error.message.contains("resumed more than once"))
            } catch {
                Issue.record("unexpected double-resume error: \(error)")
            }

            #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
            #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 0)
            #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
            #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
            #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
            #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
            #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
            #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
            #expect(interpreter.scheduledTasks.isEmpty)
        }
    }

    @Test func resultResumeUsesReturningAndThrowingTransitions()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-throwing-continuation-result-resume.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedThrowingContinuationResultResumeProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "value:29|error:failed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func resultResumeSpellingsShareTerminalTransitions()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-continuation-result-spellings.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedContinuationResultSpellingsProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "never:31|any-success:37|any-error:failed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 3)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 3)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func voidResumeUsesSameRecordAndCleanup() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-continuation-void-resume.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedContinuationVoidResumeProbe()\n"
        let interpreter = Interpreter()

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue == "void-resumed")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func delayedResumeOwnsCanonicalSuspensionAndExecutor()
        async throws
    {
        let interpreter = Interpreter()
        let gate = CheckedContinuationProducerGate()
        interpreter.globals.define(
            "waitForContinuationProducerGate",
            .hostFunction(HostFunction(
                name: "waitForContinuationProducerGate",
                asyncInvoke: { _, _ in
                    gate.entered = true
                    while !gate.isOpen { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "checkedContinuationExecutorLane",
            .hostFunction(HostFunction(
                name: "checkedContinuationExecutorLane"
            ) { _, context in
                .native(context.sourceExecutor.isMainActor ? "main" : "worker")
            }))
        let evaluation = Task {
            try await interpreter.runAsync(source: """
                @concurrent
                nonisolated
                func controlledContinuationValue() async -> String {
                    let entered = checkedContinuationExecutorLane()
                    let bodyLane: String = await withCheckedContinuation(
                        isolation: MainActor.shared
                    ) { continuation in
                        let lane = checkedContinuationExecutorLane()
                        Task.detached {
                            await waitForContinuationProducerGate()
                            continuation.resume(returning: lane)
                        }
                    }
                    let resumed = checkedContinuationExecutorLane()
                    return "\\(entered)|\\(bodyLane)|\\(resumed)"
                }

                await controlledContinuationValue()
                """)
        }
        defer {
            gate.isOpen = true
            evaluation.cancel()
        }

        var reachedWait = false
        for _ in 0..<10_000 {
            if gate.entered,
               interpreter.concurrencyRuntime.activeContinuationCount == 1 {
                reachedWait = true
                break
            }
            await Task.yield()
        }
        #expect(reachedWait)
        let continuation = try #require(
            interpreter.concurrencyRuntime.continuations.values.first)
        let owner = try #require(
            interpreter.concurrencyRuntime.records[continuation.ownerTaskID])
        let reason = RuntimeSuspension.waitingForContinuation(continuation.id)
        #expect(owner.state == .waiting)
        #expect(owner.suspension == reason)
        #expect(owner.suspensionHistory.last == reason)
        #expect(continuation.suspensionLease?.reason == reason)
        #expect(continuation.requiredExecutor == .cooperativeDefault)
        #expect(owner.evaluationContext?.currentExecutor == .cooperativeDefault)

        gate.isOpen = true
        let value = try await evaluation.value

        #expect(value.stringValue == "worker|main|worker")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func throwingMainActorErrorRestoresCallerAndCleansUp()
        async throws
    {
        let interpreter = Interpreter()
        let gate = CheckedContinuationProducerGate()
        interpreter.globals.define(
            "waitForContinuationProducerGate",
            .hostFunction(HostFunction(
                name: "waitForContinuationProducerGate",
                asyncInvoke: { _, _ in
                    gate.entered = true
                    while !gate.isOpen { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "checkedContinuationExecutorLane",
            .hostFunction(HostFunction(
                name: "checkedContinuationExecutorLane"
            ) { _, context in
                .native(context.sourceExecutor.isMainActor ? "main" : "worker")
            }))
        let evaluation = Task {
            try await interpreter.runAsync(source: """
                enum ControlledContinuationError: Error {
                    case failed
                    case wrongBodyExecutor
                }

                @concurrent
                nonisolated
                func controlledThrowingContinuation() async -> String {
                    let entered = checkedContinuationExecutorLane()
                    do {
                        let _: Int = try await withCheckedThrowingContinuation(
                            isolation: MainActor.shared
                        ) { continuation in
                            let bodyLane = checkedContinuationExecutorLane()
                            Task.detached {
                                await waitForContinuationProducerGate()
                                if bodyLane == "main" {
                                    continuation.resume(
                                        throwing: ControlledContinuationError
                                            .failed)
                                } else {
                                    continuation.resume(
                                        throwing: ControlledContinuationError
                                            .wrongBodyExecutor)
                                }
                            }
                        }
                        return "missing-error"
                    } catch ControlledContinuationError.failed {
                        let resumed = checkedContinuationExecutorLane()
                        return "\\(entered)|main|\\(resumed)"
                    } catch ControlledContinuationError.wrongBodyExecutor {
                        return "wrong-body-executor"
                    } catch {
                        return "unexpected-error"
                    }
                }

                await controlledThrowingContinuation()
                """)
        }
        defer {
            gate.isOpen = true
            evaluation.cancel()
        }

        var reachedWait = false
        for _ in 0..<10_000 {
            if gate.entered,
               interpreter.concurrencyRuntime.activeContinuationCount == 1 {
                reachedWait = true
                break
            }
            await Task.yield()
        }
        #expect(reachedWait)
        let continuation = try #require(
            interpreter.concurrencyRuntime.continuations.values.first)
        let owner = try #require(
            interpreter.concurrencyRuntime.records[continuation.ownerTaskID])
        let reason = RuntimeSuspension.waitingForContinuation(continuation.id)
        #expect(owner.state == .waiting)
        #expect(owner.suspension == reason)
        #expect(continuation.requiredExecutor == .cooperativeDefault)
        #expect(owner.evaluationContext?.currentExecutor == .cooperativeDefault)

        gate.isOpen = true
        let value = try await evaluation.value

        #expect(value.stringValue == "worker|main|worker")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func omittedIsolationUsesCallerLexicalContextAndCleansUp()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-continuation-omitted-isolation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedContinuationOmittedIsolationProbe()\n"
        let interpreter = Interpreter()
        interpreter.globals.define(
            "parityCurrentExecutorLane",
            .hostFunction(HostFunction(
                name: "parityCurrentExecutorLane"
            ) { _, context in
                .native(context.sourceExecutor.isMainActor ? "main" : "worker")
            }))

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "nonisolated=worker:worker:worker|main=main:main:main")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func hostCancellationAbortsWaitAndCleansRegistry() async throws {
        let interpreter = Interpreter()
        let evaluation = Task {
            try await interpreter.runAsync(source: """
                nonisolated func waitForAbandonedContinuation() async -> Int {
                    let value: Int = await withCheckedContinuation(
                        isolation: nil
                    ) { _ in }
                    return value
                }

                await waitForAbandonedContinuation()
                """)
        }

        var reachedWait = false
        for _ in 0..<10_000 {
            if interpreter.concurrencyRuntime.activeContinuationCount == 1 {
                reachedWait = true
                break
            }
            await Task.yield()
        }
        #expect(reachedWait)
        evaluation.cancel()
        do {
            _ = try await evaluation.value
            Issue.record("host cancellation did not abort the interpreter run")
        } catch is CancellationError {
            // Expected infrastructure abort, not a source continuation result.
        }

        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test
    func abandonedTokensWarnAcrossCheckedFormsAndCancelRemainingDrains()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cases = [
            (
                fixture: "checked-continuation-abandonment.swift",
                entry: "await checkedContinuationAbandonmentProbe()",
                function: "checkedContinuationAbandonmentProbe()"
            ),
            (
                fixture: "checked-throwing-continuation-abandonment.swift",
                entry: "await checkedThrowingContinuationAbandonmentProbe()",
                function: "checkedThrowingContinuationAbandonmentProbe()"
            ),
        ]

        for item in cases {
            let fixture = packageRoot.appendingPathComponent(
                "Tests/ConcurrencyParity/Fixtures/" + item.fixture)
            let source = try String(contentsOf: fixture, encoding: .utf8)
                + "\n\(item.entry)\n"
            let interpreter = Interpreter()

            let value = try await interpreter.runAsync(
                source: source,
                completionPolicy: .cancelRemainingTasks)

            #expect(value.stringValue == "caller-returned")
            let warning = try #require(
                interpreter.concurrencyRuntime.diagnostics.warnings.first)
            #expect(warning.contains("SWIFT TASK CONTINUATION MISUSE"))
            #expect(warning.contains(
                item.function + " leaked its continuation without resuming it"))
            #expect(warning.contains("remain suspended forever"))

            #expect(
                interpreter.concurrencyRuntime.diagnostics.warnings.count == 1)
            #expect(
                interpreter.concurrencyRuntime.totalContinuationsCreated == 1)
            #expect(
                interpreter.concurrencyRuntime.continuationSuspensionCount == 1)
            #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
            #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
            #expect(
                interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
            #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
            #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
            #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
            #expect(interpreter.scheduledTasks.isEmpty)
        }
    }

    @Test
    func escapedResumedTokensReleaseOwnerGraphAndRuntimeWithoutWarnings()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-continuation-escaped-token-lifetime.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\ntry await checkedContinuationEscapedTokenLifetimeProbe()\n"
        weak var weakInterpreter: Interpreter?
        weak var weakRuntime: CooperativeConcurrencyRuntime?
        var escapedTokens: [RuntimeSourceContinuation] = []
        var retainedDiagnostics: RuntimeDiagnosticSink?

        do {
            let interpreter = Interpreter()
            weakInterpreter = interpreter
            weakRuntime = interpreter.concurrencyRuntime
            retainedDiagnostics = interpreter.concurrencyRuntime.diagnostics

            let value = try await interpreter.runAsync(source: source)

            #expect(value.stringValue
                == "true:47:true:true|true:53:true:true")
            for name in [
                "checkedContinuationEscapedNonthrowingToken",
                "checkedContinuationEscapedThrowingToken",
            ] {
                let value = try #require(
                    interpreter.globals.lookup(name)?.unwrappedOptionalOrSelf)
                guard case .host(let payload) = value,
                      let token = payload as? RuntimeSourceContinuation else {
                    Issue.record("\(name) did not retain a continuation token")
                    continue
                }
                escapedTokens.append(token)
            }

            #expect(escapedTokens.count == 2)
            #expect(
                interpreter.concurrencyRuntime.diagnostics.warnings.isEmpty)
            #expect(
                interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
            #expect(
                interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
            #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
            #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
            #expect(
                interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
            #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
            #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
            #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
            #expect(interpreter.scheduledTasks.isEmpty)
        }

        #expect(weakInterpreter == nil)
        #expect(weakRuntime == nil)
        #expect(escapedTokens.count == 2)
        #expect(retainedDiagnostics?.warnings.isEmpty == true)
        escapedTokens.removeAll()
        #expect(retainedDiagnostics?.warnings.isEmpty == true)
    }

    @Test func sourceActorIsolationOwnsBodyReentersAndCleansUp()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-continuation-source-actor-isolation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedContinuationSourceActorIsolationProbe()\n"
        let interpreter = Interpreter()
        installSourceActorIsolationSupport(on: interpreter)

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "explicit=worker:owned:worker|default=owned:owned:owned:1")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.actors.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    @Test func throwingSourceActorIsolationRestoresErrorAndCleansUp()
        async throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/"
                + "checked-throwing-continuation-source-actor-isolation.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nawait checkedThrowingContinuationSourceActorIsolationProbe()\n"
        let interpreter = Interpreter()
        installSourceActorIsolationSupport(on: interpreter)

        let value = try await interpreter.runAsync(source: source)

        #expect(value.stringValue
            == "explicit=worker:owned:worker|default=owned:owned:failed:owned:1")
        #expect(interpreter.concurrencyRuntime.totalContinuationsCreated == 2)
        #expect(interpreter.concurrencyRuntime.continuationSuspensionCount == 2)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.actors.isEmpty)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeAsyncStreamCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
    }

    private func installSourceActorIsolationSupport(
        on interpreter: Interpreter
    ) {
        let gate = CheckedContinuationProducerGate()
        interpreter.globals.define(
            "parityCurrentExecutorLane",
            .hostFunction(HostFunction(
                name: "parityCurrentExecutorLane"
            ) { _, context in
                .native(context.sourceExecutor.isMainActor ? "main" : "worker")
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
        interpreter.globals.define(
            "parityAssertActorSegmentOwnership",
            .hostFunction(HostFunction(
                name: "parityAssertActorSegmentOwnership"
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
            "parityWaitTaskValueGate",
            .hostFunction(HostFunction(
                name: "parityWaitTaskValueGate",
                asyncInvoke: { _, _ in
                    gate.entered = true
                    while !gate.isOpen { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "parityAwaitTaskValueGateStarted",
            .hostFunction(HostFunction(
                name: "parityAwaitTaskValueGateStarted",
                asyncInvoke: { _, _ in
                    while !gate.entered { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "parityOpenTaskValueGate",
            .hostFunction(HostFunction(
                name: "parityOpenTaskValueGate"
            ) { _, _ in
                gate.isOpen = true
                return .void
            }))
    }
}
