import Foundation
import SwiftSyntax

/// Immutable lexical placement of one selected source function declaration.
/// This is not a runtime receiver: it deliberately carries no Instance,
/// Environment, Box, symbol, or evaluator capability.
nonisolated enum RuntimeSourceFunctionLexicalPlacement: Sendable, Equatable {
    case global
    case lexicalType(
        name: String,
        isTypeMember: Bool,
        isActor: Bool)
}

/// The declaration isolation facts known when the selected source closure is
/// formed. Named global actors remain candidates until the session resolves
/// their canonical `shared` actor at invocation.
nonisolated enum RuntimeSourceFunctionIsolation: Sendable, Equatable {
    case inherited
    case explicitlyNonisolated
    case executor(RuntimeExecutorKind)
    case lazyGlobalActorCandidates([String])
}

/// Executor-neutral identity projected from an exact selected source
/// declaration. The originating plan is part of the identity: a
/// SyntaxIdentifier is meaningful only in the syntax tree that created it.
nonisolated struct RuntimeSourceFunctionTargetDescriptor:
    Sendable, Equatable
{
    let originProgramPlan: ResolvedProgramPlan
    let declarationID: SyntaxIdentifier
    let sourceFunctionName: String
    let lexicalPlacement: RuntimeSourceFunctionLexicalPlacement
    let isolation: RuntimeSourceFunctionIsolation
    let isAsync: Bool
    let isThrowing: Bool
    let returnTypeName: String?

    static func == (
        lhs: RuntimeSourceFunctionTargetDescriptor,
        rhs: RuntimeSourceFunctionTargetDescriptor
    ) -> Bool {
        lhs.originProgramPlan === rhs.originProgramPlan
            && lhs.declarationID == rhs.declarationID
            && lhs.sourceFunctionName == rhs.sourceFunctionName
            && lhs.lexicalPlacement == rhs.lexicalPlacement
            && lhs.isolation == rhs.isolation
            && lhs.isAsync == rhs.isAsync
            && lhs.isThrowing == rhs.isThrowing
            && lhs.returnTypeName == rhs.returnTypeName
    }
}

/// MainActor-confined resolution product. Only `descriptor` may cross a
/// physical-worker boundary; the selected closure remains with the evaluator.
@MainActor
struct RuntimeResolvedSourceFunctionCall {
    let descriptor: RuntimeSourceFunctionTargetDescriptor
    let closure: ClosureValue
}

/// Result subset admitted by the first physical source-call command. The
/// FoodTruck method returns Void while the bounded parity oracle returns a
/// String; richer result types stay on the cooperative evaluator until they
/// receive their own demand-backed slice.
nonisolated enum RuntimePhysicalSourceCallResultKind: Sendable, Equatable {
    case void
    case string

    init?(returnTypeName: String?) {
        switch returnTypeName?.trimmingCharacters(
            in: .whitespacesAndNewlines) {
        case nil, "", "Void", "()":
            self = .void
        case "String":
            self = .string
        default:
            return nil
        }
    }

    func accepts(_ snapshot: RuntimeWorkerValueSnapshot) -> Bool {
        switch (self, snapshot) {
        case (.void, .void), (.string, .string):
            true
        default:
            false
        }
    }
}

/// The complete executor-neutral command carried by the physical detached
/// wrapper. It identifies an already selected declaration and its owning
/// logical task, but contains no receiver, closure, environment, program
/// state, heap, or evaluator capability.
nonisolated struct RuntimePhysicalSourceCallCommand: Sendable, Equatable {
    let entryID: RuntimeSessionID
    let taskID: RuntimeTaskID
    let target: RuntimeSourceFunctionTargetDescriptor
    let resultKind: RuntimePhysicalSourceCallResultKind
}

/// Confined half of a physical source-call command. RuntimeTaskRecord owns it
/// for exactly the source task lifetime; only the matching Sendable command
/// can ask the MainActor relay to use it.
@MainActor
struct RuntimeRegisteredPhysicalSourceCall {
    let command: RuntimePhysicalSourceCallCommand
    let target: RuntimeResolvedSourceFunctionCall
}

/// Purpose-built executor gateway for a physical detached wrapper. A worker
/// may retain this globally isolated reference and a typed command, but the
/// selected closure and evaluator state never leave MainActor. Re-entry
/// reinstalls the original source task context before invoking the method.
@MainActor
final class RuntimeSourceCallReentryRelay {
    private weak var runtime: CooperativeConcurrencyRuntime?

    init(runtime: CooperativeConcurrencyRuntime) {
        self.runtime = runtime
    }

    func invoke(
        _ command: RuntimePhysicalSourceCallCommand,
        capability: RuntimeWorkerCapability,
        handoff: RuntimePhysicalSourceExecutorHandoff
    ) async throws -> RuntimeWorkerValueSnapshot {
        // This method is MainActor-isolated. Opening the one-shot handoff here
        // proves the detached wrapper has relinquished its physical executor;
        // an indefinitely suspended source method must not own a worker slot.
        await handoff.reachedConfinedExecutor()
        guard capability.accessManifest.isWorkerSafe,
              capability.entryID == command.entryID,
              capability.programPlan === command.target.originProgramPlan
        else {
            throw failure("source-call command has mismatched worker provenance")
        }
        guard let runtime,
              let record = runtime.records[command.taskID],
              record.entry.id == command.entryID,
              record.state == .running,
              let registered = record.physicalSourceCall,
              registered.command == command,
              registered.target.descriptor == command.target,
              let context = record.evaluationContext,
              let interpreter = record.entry.interpreter else {
            throw failure("source-call command lost its confined runtime entry")
        }

        return try await EvaluationTaskContext.$current.withValue(context) {
            let value = try await interpreter.callBackgroundClosureSuspending(
                registered.target.closure,
                arguments: [])
            let snapshot = try RuntimeWorkerValueSnapshot.copying(value)
            guard command.resultKind.accepts(snapshot) else {
                throw failure(
                    "source-call command produced an unsupported result shape")
            }
            return snapshot
        }
    }

    private func failure(_ message: String) -> RuntimeError {
        RuntimeError(message: "physical \(message)", fatal: true)
    }
}

extension Interpreter {
    func sourceFunctionTargetDescriptor(
        declarationID: SyntaxIdentifier,
        metadata: ParsedFunctionMetadata,
        closure: ClosureValue
    ) -> RuntimeSourceFunctionTargetDescriptor? {
        guard let originProgramPlan = closure.programPlan else {
            return nil
        }

        let lexicalPlacement: RuntimeSourceFunctionLexicalPlacement
        if let owner = closure.lexicalOwner as? StructSymbol {
            lexicalPlacement = .lexicalType(
                name: owner.name,
                isTypeMember: metadata.isTypeMember,
                isActor: owner.isActor)
        } else if let owner = closure.lexicalOwner as? EnumSymbol {
            lexicalPlacement = .lexicalType(
                name: owner.name,
                isTypeMember: metadata.isTypeMember,
                isActor: false)
        } else if closure.lexicalOwner == nil {
            lexicalPlacement = .global
        } else {
            return nil
        }

        let isolation: RuntimeSourceFunctionIsolation
        if let executor = closure.executorPreference {
            isolation = .executor(executor)
        } else if closure.isExplicitlyNonisolated {
            isolation = .explicitlyNonisolated
        } else if !closure.globalActorAttributeCandidates.isEmpty {
            isolation = .lazyGlobalActorCandidates(
                closure.globalActorAttributeCandidates)
        } else {
            isolation = .inherited
        }

        return RuntimeSourceFunctionTargetDescriptor(
            originProgramPlan: originProgramPlan,
            declarationID: declarationID,
            sourceFunctionName: metadata.sourceFunctionName,
            lexicalPlacement: lexicalPlacement,
            isolation: isolation,
            isAsync: metadata.isAsync,
            isThrowing: metadata.isThrowing,
            returnTypeName: metadata.returnTypeName)
    }

    /// Resolve only an own reference-type method for which call shape selects
    /// exactly one declaration. Same-shape overloads, properties, source
    /// structs, inherited/default witnesses, and absent origin metadata fail
    /// closed instead of fabricating compiler-level overload knowledge.
    func resolveOwnSourceInstanceMethodCallTarget(
        named name: String,
        on instance: Instance,
        arguments: CallArguments
    ) -> RuntimeResolvedSourceFunctionCall? {
        guard instance.symbol.isClass,
              instance.box(for: name) == nil,
              instance.symbol.computedProperties[name] == nil,
              let overloads = instance.symbol.methods[name],
              !overloads.isEmpty else {
            return nil
        }

        let available = overloads.count > 1
            ? overloads.filter { !activeFunctionBodies.contains($0.id) }
            : overloads
        let argumentShape = ArgumentShape(arguments)
        let fitting = available.filter {
            functionMetadata(for: $0).shape.matches(argumentShape)
        }
        guard fitting.count == 1,
              let method = fitting.first,
              let body = functionMetadata(for: method).body else {
            return nil
        }

        let closure = makeFunctionClosure(
            method,
            body: body,
            captured: instanceMethodEnvironment(instance),
            originProgramState: instance.programState)
        guard let descriptor = closure.sourceFunctionTargetDescriptor else {
            return nil
        }
        return RuntimeResolvedSourceFunctionCall(
            descriptor: descriptor,
            closure: closure)
    }
}
