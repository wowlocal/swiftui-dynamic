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
    /// Result of the exact `await weakSelf?.voidMethod()` wrapper. Both a live
    /// receiver (`.some(())`) and a released receiver (`.none`) are values.
    case optionalVoid

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
        case (.optionalVoid, .optional(
            wrapped: let wrapped,
            wrappedTypeName: _,
            isImplicitlyUnwrapped: false
        )):
            wrapped == nil || wrapped == .void
        default:
            false
        }
    }
}

/// One evaluated source argument carried by name through the checked worker
/// capability. Labels remain in the command so confined re-entry can bind the
/// exact selected declaration without sending a CallArguments value.
nonisolated enum RuntimePhysicalSourceCallValueKind: Sendable, Equatable {
    case integer
    case boolean
    case string
    case stringArray
    case url

    func accepts(_ snapshot: RuntimeWorkerValueSnapshot) -> Bool {
        switch (self, snapshot) {
        case (.integer, .int), (.boolean, .bool), (.string, .string),
             (.url, .url):
            true
        case (.stringArray, .array(let values)):
            values.allSatisfy { value in
                if case .string = value { return true }
                return false
            }
        default:
            false
        }
    }

    func accepts(parameterTypeName: String?) -> Bool {
        if self == .stringArray {
            return RuntimeDeclaredType.arrayElementTypeName(
                in: parameterTypeName) == "String"
        }
        return switch (
            self,
            RuntimeDeclaredType.nominalTypeName(parameterTypeName)
        ) {
        case (.integer, "Int"), (.integer, "Int64"), (.boolean, "Bool"),
             (.string, "String"), (.url, "URL"):
            true
        default:
            false
        }
    }
}

/// Source provenance is part of physical admission rather than inferred from
/// a synthetic binding name. Route proofs can therefore distinguish a
/// side-effect-free literal from a directly owned immutable capture without
/// widening every route that accepts the same value kind.
nonisolated enum RuntimePhysicalSourceCallArgumentOrigin: Sendable, Equatable {
    case literal
    case capturedImmutable
    /// A direct `self.member` read proven to select one plain, non-lazy,
    /// immutable stored property on the same source instance. Admission reads
    /// the initialized box while confined and never executes a getter.
    case storedImmutableMember
}

nonisolated struct RuntimePhysicalSourceCallArgument: Sendable, Equatable {
    let label: String?
    let bindingName: String
    let valueKind: RuntimePhysicalSourceCallValueKind
    let origin: RuntimePhysicalSourceCallArgumentOrigin
}

/// How the authored source expression handles an error from the confined
/// method invocation. The worker never receives an interpreted thrown value:
/// `try?` containment happens while the evaluator is still on MainActor and
/// only the resulting Optional snapshot crosses back to the worker.
nonisolated enum RuntimePhysicalSourceCallErrorDisposition:
    Sendable, Equatable
{
    case propagate
    case suppressToOptional
}

/// The complete executor-neutral command carried by the physical detached
/// wrapper. It identifies an already selected declaration and its owning
/// logical task, but contains no receiver, closure, environment, program
/// state, heap, or evaluator capability.
nonisolated struct RuntimePhysicalSourceCallCommand: Sendable, Equatable {
    let entryID: RuntimeSessionID
    let taskID: RuntimeTaskID
    let target: RuntimeSourceFunctionTargetDescriptor
    let arguments: [RuntimePhysicalSourceCallArgument]
    let resultKind: RuntimePhysicalSourceCallResultKind
    let errorDisposition: RuntimePhysicalSourceCallErrorDisposition
}

/// Confined invocation data selected for a physical source-call command. A
/// strong/direct route may retain its already resolved method closure. A weak
/// optional-self route retains only the source operation closure, whose `self`
/// box is genuinely weak; it resolves and temporarily strengthens the receiver
/// only after the detached wrapper reaches MainActor re-entry.
@MainActor
enum RuntimeRegisteredPhysicalSourceCallInvocation {
    case resolved(RuntimeResolvedSourceFunctionCall)
    case weakSelfOptional(sourceClosure: ClosureValue, methodName: String)
}

/// Confined half of a physical source-call command. RuntimeTaskRecord owns it
/// for exactly the source task lifetime; only the matching Sendable command
/// can ask the MainActor relay to use it.
@MainActor
struct RuntimeRegisteredPhysicalSourceCall {
    let command: RuntimePhysicalSourceCallCommand
    let invocation: RuntimeRegisteredPhysicalSourceCallInvocation
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
              capability.programPlan === command.target.originProgramPlan,
              capability.bindings.count == command.arguments.count
        else {
            throw failure("source-call command has mismatched worker provenance")
        }
        guard let runtime,
              let record = runtime.records[command.taskID],
              record.entry.id == command.entryID,
              record.state == .running,
              let registered = record.physicalSourceCall,
              registered.command == command,
              let context = record.evaluationContext,
              let interpreter = record.entry.interpreter else {
            throw failure("source-call command lost its confined runtime entry")
        }

        return try await EvaluationTaskContext.$current.withValue(context) {
            var arguments: [CallArguments.Argument] = []
            arguments.reserveCapacity(command.arguments.count)
            for (argument, binding) in zip(
                command.arguments, capability.bindings
            ) {
                guard argument.bindingName == binding.name,
                      argument.valueKind.accepts(binding.value) else {
                    throw failure(
                        "source-call command has mismatched argument provenance")
                }
                arguments.append(.init(
                    label: argument.label,
                    value: binding.value.materializedRuntimeValue()))
            }
            let callArguments = CallArguments(arguments: arguments)
            let value: RuntimeValue
            do {
                let invokedValue: RuntimeValue
                switch registered.invocation {
                case .resolved(let target):
                    guard target.descriptor == command.target else {
                        throw failure(
                            "source-call command changed its resolved target")
                    }
                    invokedValue = try await interpreter
                        .callBackgroundClosureSuspending(
                            target.closure,
                            arguments: callArguments)

                case .weakSelfOptional(let sourceClosure, let methodName):
                    guard command.resultKind == .optionalVoid,
                          command.errorDisposition == .propagate,
                          sourceClosure.isPhysicalWeakSelfSourceCallCandidate,
                          let selfBox = sourceClosure.captured.box(
                            for: "self", before: interpreter.globals),
                          selfBox.referenceOwnership == .weak else {
                        throw failure(
                            "weak-self source-call registration is invalid")
                    }
                    switch try selfBox.load().optionalState {
                    case .none:
                        invokedValue = .none()
                    case .some(.instance(let instance), _):
                        guard let target = interpreter
                            .resolveOwnSourceInstanceMethodCallTarget(
                                named: methodName,
                                on: instance,
                                arguments: callArguments),
                              target.descriptor == command.target else {
                            throw failure(
                                "weak-self source-call target changed before re-entry")
                        }
                        let result = try await interpreter
                            .callBackgroundClosureSuspending(
                                target.closure,
                                arguments: callArguments)
                        invokedValue = result.liftedToOptional()
                    case .some, .notOptional:
                        throw failure(
                            "weak-self source-call receiver has an invalid shape")
                    }
                }
                switch command.errorDisposition {
                case .propagate:
                    value = invokedValue
                case .suppressToOptional:
                    value = invokedValue.liftedToOptional()
                }
            } catch is InterpreterSessionAbort {
                // Session teardown is evaluator control flow, not a source
                // Error value, and therefore remains uncatchable by try?.
                throw InterpreterSessionAbort()
            } catch let runtimeError as RuntimeError
                where runtimeError.fatal
            {
                // Interpreted traps remain contained by the runtime task, but
                // authored try? must not turn them into an ordinary nil.
                throw runtimeError
            } catch {
                guard command.errorDisposition == .suppressToOptional else {
                    throw error
                }
                // Includes InterpretedThrow while its RuntimeValue remains
                // confined. Only Optional.none is materialized for the worker.
                value = .none()
            }
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

    /// Resolve one static default supplied by a protocol extension while
    /// preserving the concrete conformer as dynamic `Self`. Own static
    /// members win before this path, and multiple fitting defaults fail
    /// closed because the interpreter does not yet model compiler constraint
    /// ranking for protocol-extension overloads.
    func resolveUniqueProtocolExtensionStaticMethodCallTarget(
        named name: String,
        onConformingType symbol: StructSymbol,
        arguments: CallArguments
    ) -> RuntimeResolvedSourceFunctionCall? {
        guard symbol.staticMethods[name] == nil,
              symbol.staticProperties[name] == nil,
              symbol.staticComputedProperties[name] == nil,
              symbol.staticWrapped[name] == nil,
              !symbol.staticUninitialized.contains(name),
              symbol.taskLocalProperties[name] == nil,
              symbol.nestedTypes[name] == nil else {
            return nil
        }

        let argumentShape = ArgumentShape(arguments)
        var fitting: [FunctionDeclSyntax] = []
        for conformance in transitiveConformances(of: symbol) {
            guard let overloads = hostExtensionSymbols[conformance]?
                .staticMethods[name] else {
                continue
            }
            fitting.append(contentsOf: overloads.filter { declaration in
                let metadata = programStateOwningDeclaration(declaration.id)?
                    .programPlan?.metadata.extensionMetadataIndex.metadata(
                        containing: declaration)
                    ?? currentProgramMetadata?.extensionMetadataIndex.metadata(
                        containing: declaration)
                return !activeFunctionBodies.contains(declaration.id)
                    && functionMetadata(for: declaration).shape.matches(
                        argumentShape)
                    && functionMetadata(for: declaration).body != nil
                    && metadata?.genericRequirements.isEmpty == true
                    && metadata?.attributeNames.isEmpty == true
                    && metadata?.modifierNames.isEmpty == true
            })
        }
        guard fitting.count == 1,
              let method = fitting.first,
              let body = functionMetadata(for: method).body else {
            return nil
        }

        let closure = makeFunctionClosure(
            method,
            body: body,
            captured: selfEnvironment(.type(symbol)))
        guard let descriptor = closure.sourceFunctionTargetDescriptor,
              case .lexicalType(
                _, isTypeMember: true, isActor: false
              ) = descriptor.lexicalPlacement else {
            return nil
        }
        return RuntimeResolvedSourceFunctionCall(
            descriptor: descriptor,
            closure: closure)
    }

    /// Resolve a contextual static factory declared on a protocol extension
    /// whose sole same-type requirement proves the concrete `Self`.
    ///
    /// This is the inverse of ordinary protocol-default lookup: the expected
    /// existential supplies the protocol, interface metadata supplies the
    /// concrete conformer, and the declared return type must preserve that
    /// same concrete identity. No protocol, member, or nominal spelling is
    /// privileged.
    func resolveUniqueConstrainedProtocolStaticFactoryCallTarget(
        named name: String,
        inContextualProtocol protocolName: String,
        arguments: CallArguments
    ) -> RuntimeResolvedSourceFunctionCall? {
        guard protocolInheritance[protocolName] != nil,
              let overloads = hostExtensionSymbols[protocolName]?
                .staticMethods[name] else {
            return nil
        }

        struct Candidate {
            let declaration: FunctionDeclSyntax
            let concreteType: StructSymbol
        }

        func visibleType(
            named typeName: String,
            for declaration: FunctionDeclSyntax
        ) -> RuntimeValue? {
            let state = programStateOwningDeclaration(declaration.id)
            let metadata = state?.programPlan?.metadata
                ?? currentProgramMetadata
            let position = declaration.positionAfterSkippingLeadingTrivia
            return lexicallyVisibleType(
                named: typeName,
                from: state?.lexicalOwner(of: declaration.id),
                sourceModuleName: metadata?.sourceModuleName(at: position),
                sourceImportedModuleNames:
                    metadata?.sourceImportedModuleNames(at: position))
        }

        let fitting = functionsFittingCall(
            from: overloads.filter { declaration in
                guard !activeFunctionBodies.contains(declaration.id),
                      functionMetadata(for: declaration).body != nil else {
                    return false
                }
                let extensionMetadata =
                    programStateOwningDeclaration(declaration.id)?
                        .programPlan?.metadata.extensionMetadataIndex.metadata(
                            containing: declaration)
                    ?? currentProgramMetadata?.extensionMetadataIndex.metadata(
                        containing: declaration)
                return extensionMetadata?.attributeNames.isEmpty == true
                    && extensionMetadata?.modifierNames.isEmpty == true
                    && extensionMetadata?
                        .soleSelfSameTypeConcreteTypeName != nil
            },
            args: arguments)
        let candidates = fitting.compactMap { declaration -> Candidate? in
            let extensionMetadata =
                programStateOwningDeclaration(declaration.id)?
                    .programPlan?.metadata.extensionMetadataIndex.metadata(
                        containing: declaration)
                ?? currentProgramMetadata?.extensionMetadataIndex.metadata(
                    containing: declaration)
            guard let concreteName = extensionMetadata?
                    .soleSelfSameTypeConcreteTypeName,
                  case .type(let concreteType)? = visibleType(
                    named: concreteName, for: declaration),
                  transitiveConformances(of: concreteType).contains(
                    where: {
                        HostSignature.equivalentTypeName($0, protocolName)
                    }),
                  let returnTypeName = functionMetadata(
                    for: declaration).returnTypeName else {
                return nil
            }
            if returnTypeName != "Self" {
                guard case .type(let returnType)? = visibleType(
                    named: returnTypeName, for: declaration),
                      returnType === concreteType else {
                    return nil
                }
            }
            return Candidate(
                declaration: declaration,
                concreteType: concreteType)
        }
        guard candidates.count == 1,
              let candidate = candidates.first,
              let body = functionMetadata(
                for: candidate.declaration).body else {
            return nil
        }

        let closure = makeFunctionClosure(
            candidate.declaration,
            body: body,
            captured: selfEnvironment(.type(candidate.concreteType)))
        guard let descriptor = closure.sourceFunctionTargetDescriptor,
              case .lexicalType(
                _, isTypeMember: true, isActor: false
              ) = descriptor.lexicalPlacement else {
            return nil
        }
        return RuntimeResolvedSourceFunctionCall(
            descriptor: descriptor,
            closure: closure)
    }
}
