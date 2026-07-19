/// Executor-neutral identity for a detached worker prefix whose remaining
/// source body must resume inside the originating evaluator. The command is a
/// token only: the suffix closure and its eventual RuntimeValue/Error stay on
/// MainActor in the matching RuntimeTaskRecord.
nonisolated struct RuntimePhysicalSourceContinuationCommand:
    Sendable, Equatable
{
    let entryID: RuntimeSessionID
    let taskID: RuntimeTaskID
}

/// A source continuation may finish with values and errors that are not
/// Sendable. Keep the complete outcome confined, then let the owning logical
/// task consume it after the physical wrapper returns a Sendable completion
/// token.
@MainActor
enum RuntimeConfinedPhysicalSourceOutcome {
    case success(RuntimeValue)
    case failure(any Error)
}

/// Confined half of a physical-prefix command. RuntimeTaskRecord owns this for
/// exactly the source-task lifetime; no worker receives the closure, captured
/// environment, evaluator state, RuntimeValue, or Error stored here.
@MainActor
final class RuntimeRegisteredPhysicalSourceContinuation {
    let command: RuntimePhysicalSourceContinuationCommand
    let suffix: ClosureValue
    private(set) var outcome: RuntimeConfinedPhysicalSourceOutcome?

    init(
        command: RuntimePhysicalSourceContinuationCommand,
        suffix: ClosureValue
    ) {
        self.command = command
        self.suffix = suffix
    }

    func publish(_ outcome: RuntimeConfinedPhysicalSourceOutcome) {
        precondition(self.outcome == nil)
        self.outcome = outcome
    }
}

/// Purpose-built MainActor gateway for a detached worker prefix. Re-entry
/// reinstalls the source task's EvaluationTaskContext, runs only the retained
/// suffix, and stores its confined outcome before returning a plain Void
/// snapshot to the worker.
@MainActor
final class RuntimeSourceContinuationReentryRelay {
    private weak var runtime: CooperativeConcurrencyRuntime?

    init(runtime: CooperativeConcurrencyRuntime) {
        self.runtime = runtime
    }

    func invoke(
        _ command: RuntimePhysicalSourceContinuationCommand,
        capability: RuntimeWorkerCapability,
        handoff: RuntimePhysicalSourceExecutorHandoff
    ) async throws -> RuntimeWorkerValueSnapshot {
        await handoff.reachedConfinedExecutor()
        guard capability.accessManifest.isWorkerSafe,
              capability.entryID == command.entryID,
              capability.bindings.isEmpty else {
            throw failure(
                "source-continuation command has mismatched worker provenance")
        }
        guard let runtime,
              let record = runtime.records[command.taskID],
              record.entry.id == command.entryID,
              record.state == .running,
              let registered = record.physicalSourceContinuation,
              registered.command == command,
              registered.suffix.programPlan === record.entry.programPlan,
              let context = record.evaluationContext,
              let interpreter = record.entry.interpreter else {
            throw failure(
                "source-continuation command lost its confined runtime entry")
        }

        let outcome: RuntimeConfinedPhysicalSourceOutcome =
            await EvaluationTaskContext.$current.withValue(context) {
                do {
                    return .success(try await interpreter
                        .callBackgroundClosureSuspending(
                            registered.suffix,
                            arguments: [],
                            inheritsAnonymousClosureLexicalExecutor: false))
                } catch {
                    return .failure(error)
                }
            }
        guard record.physicalSourceContinuation === registered else {
            throw failure(
                "source-continuation registration changed during re-entry")
        }
        registered.publish(outcome)
        return .void
    }

    private func failure(_ message: String) -> RuntimeError {
        RuntimeError(message: "physical \(message)", fatal: true)
    }
}

extension CooperativeConcurrencyRuntime {
    /// Redeem the worker's Sendable completion token on MainActor. Removing
    /// the registration before projecting the outcome releases the retained
    /// suffix on both success and failure paths.
    func takePhysicalSourceContinuationOutcome(
        _ command: RuntimePhysicalSourceContinuationCommand
    ) throws -> RuntimeValue {
        guard let record = records[command.taskID],
              record.entry.id == command.entryID,
              let registered = record.physicalSourceContinuation,
              registered.command == command,
              let outcome = registered.outcome else {
            throw RuntimeError(
                message: "physical source continuation has no confined outcome",
                fatal: true)
        }
        record.physicalSourceContinuation = nil
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}
