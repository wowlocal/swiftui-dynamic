import SwiftSyntax

/// Typed, executor-neutral expression IR admitted at the physical boundary.
/// It is deliberately not a second evaluator: each case is backed by a real
/// demand citation and consumes only recursively copied worker snapshots.
nonisolated indirect enum RuntimeSourceSnapshotExpression:
    Sendable, Equatable
{
    case binding(String)
    case stringCount(RuntimeSourceSnapshotExpression)
    case stringCountSum(RuntimeSourceSnapshotExpression)
    case stringStartIndex(RuntimeSourceSnapshotExpression)
    case stringDistance(
        RuntimeSourceSnapshotExpression,
        from: RuntimeSourceSnapshotExpression,
        to: RuntimeSourceSnapshotExpression)

    func execute(
        with capability: RuntimeWorkerCapability
    ) throws -> RuntimeWorkerValueSnapshot {
        switch self {
        case .binding(let name):
            guard let binding = capability.bindings.first(where: {
                $0.name == name
            }) else {
                throw RuntimeError(message:
                    "physical source expression has no copied binding '\(name)'")
            }
            return binding.value
        case .stringCount(let base):
            guard case .string(let value) = try base.execute(
                with: capability) else {
                throw RuntimeError(message:
                    "physical String.count kernel received a non-String snapshot")
            }
            return .int(value.count)
        case .stringCountSum(let base):
            guard case .array(let values) = try base.execute(
                with: capability) else {
                throw RuntimeError(message:
                    "physical String-count reduction received a non-array snapshot")
            }
            var total = 0
            for value in values {
                guard case .string(let string) = value else {
                    throw RuntimeError(message:
                        "physical String-count reduction received a non-String element")
                }
                let addition = total.addingReportingOverflow(string.count)
                guard !addition.overflow else {
                    throw RuntimeError(message:
                        "physical String-count reduction overflowed Int")
                }
                total = addition.partialValue
            }
            return .int(total)
        case .stringStartIndex(let base):
            guard case .string(let value) = try base.execute(
                with: capability) else {
                throw RuntimeError(message:
                    "physical String.startIndex kernel received a non-String snapshot")
            }
            return .stringIndex(value.startIndex)
        case .stringDistance(let base, let from, let to):
            guard case .string(let value) = try base.execute(
                with: capability),
                  case .stringIndex(let lower) = try from.execute(
                    with: capability),
                  case .stringIndex(let upper) = try to.execute(
                    with: capability) else {
                throw RuntimeError(message:
                    "physical String.distance kernel received invalid snapshots")
            }
            return .int(value.distance(from: lower, to: upper))
        }
    }
}

/// Typed duration selection for a demand-cited suspending worker command.
/// Duration constants are lowered on MainActor; the worker may select between
/// them only from a recursively copied Bool binding.
nonisolated indirect enum RuntimeSourceSnapshotDurationExpression:
    Sendable, Equatable
{
    case constant(RuntimeDuration)
    case conditional(
        condition: RuntimeSourceSnapshotExpression,
        ifTrue: RuntimeSourceSnapshotDurationExpression,
        ifFalse: RuntimeSourceSnapshotDurationExpression)

    func execute(
        with capability: RuntimeWorkerCapability
    ) throws -> RuntimeDuration {
        switch self {
        case .constant(let duration):
            return duration
        case .conditional(let condition, let ifTrue, let ifFalse):
            guard case .bool(let value) = try condition.execute(
                with: capability) else {
                throw RuntimeError(message:
                    "physical conditional Duration kernel received a non-Bool snapshot")
            }
            return try (value ? ifTrue : ifFalse).execute(with: capability)
        }
    }
}

/// A source operation either observes cancellation or does not. The physical
/// driver uses this language fact to distinguish Swift's cooperative finite
/// bodies from cancellation-checking suspensions such as throwing sleep.
nonisolated enum RuntimeSourceKernelCancellationBehavior:
    Sendable, Equatable
{
    case unobserved
    case observed
}

/// Executor-neutral work lowered from an explicitly admitted source closure.
/// The demand-scoped surface is a literal or a typed snapshot expression. The
/// kernel owns no syntax, evaluator, environment, closure, heap, or host value.
nonisolated enum RuntimeSourceSnapshotKernel: Sendable, Equatable {
    case constant(RuntimeWorkerValueSnapshot)
    case expression(RuntimeSourceSnapshotExpression)
    case taskYield
    case taskSleep(RuntimeSourceSnapshotDurationExpression)
    case taskSleepNanoseconds(UInt64)

    var cancellationBehavior: RuntimeSourceKernelCancellationBehavior {
        switch self {
        case .constant, .expression, .taskYield:
            return .unobserved
        case .taskSleep, .taskSleepNanoseconds:
            return .observed
        }
    }

    func execute(
        with capability: RuntimeWorkerCapability
    ) async throws -> RuntimeWorkerValueSnapshot {
        guard capability.accessManifest.isWorkerSafe else {
            throw RuntimeError(message:
                "physical source kernel received an unsafe worker manifest")
        }
        switch self {
        case .constant(let value):
            return value
        case .expression(let expression):
            return try expression.execute(with: capability)
        case .taskYield:
            await Task.yield()
            return .void
        case .taskSleep(let durationExpression):
            let duration = try durationExpression.execute(with: capability)
            try await Task.sleep(for: .nanoseconds(duration.nanoseconds))
            return .void
        case .taskSleepNanoseconds(let nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            return .void
        }
    }
}

/// Source-specific metadata kept beside the generic checked worker job. It
/// contains no evaluator or heap capability and lets the driver preserve the
/// source operation's own cancellation-observation rule.
nonisolated struct RuntimePhysicalSourceKernelJob: Sendable {
    let workerJob: RuntimePhysicalWorkerJob
    let cancellationBehavior: RuntimeSourceKernelCancellationBehavior
    let permitLifetime: RuntimePhysicalSourcePermitLifetime
    let confinedContinuationCommand:
        RuntimePhysicalSourceContinuationCommand?

    init(
        workerJob: RuntimePhysicalWorkerJob,
        cancellationBehavior: RuntimeSourceKernelCancellationBehavior,
        permitLifetime: RuntimePhysicalSourcePermitLifetime = .operation,
        confinedContinuationCommand:
            RuntimePhysicalSourceContinuationCommand? = nil
    ) {
        self.workerJob = workerJob
        self.cancellationBehavior = cancellationBehavior
        self.permitLifetime = permitLifetime
        self.confinedContinuationCommand = confinedContinuationCommand
    }
}

extension Interpreter {
    /// Lower only proven `Task.detached` snapshot expressions. Every
    /// unsupported statement/expression/capture shape returns nil and keeps
    /// using the cooperative evaluator; there is no best-effort worker
    /// interpretation.
    func makePhysicalSourceKernelJob(
        closure: ClosureValue,
        arguments: [RuntimeValue],
        entry: RuntimeEntry,
        record: RuntimeTaskRecord,
        priority: RuntimeTaskPriority
    ) throws -> RuntimePhysicalSourceKernelJob? {
        guard physicalWorkerDriver != nil,
              arguments.isEmpty,
              closure.parameters.isEmpty,
              !closure.isBuilder,
              (closure.isPhysicalSnapshotKernelCandidate
                || closure
                    .isPhysicalExplicitMainActorContinuationCandidate
                || closure.isPhysicalStrongSelfSourceCallCandidate
                || closure.isPhysicalWeakSelfSourceCallCandidate) else {
            return nil
        }

        if let prefix = try physicalTryOptionalSleepPrefixJob(
            closure: closure,
            entry: entry,
            record: record,
            priority: priority) {
            return prefix
        }

        guard
              closure.body.count == 1,
              let item = closure.body.first,
              let expression = Self.singleExpression(in: item) else {
            return nil
        }

        if let mainActorContinuation = try physicalMainActorContinuationJob(
            expression,
            closure: closure,
            entry: entry,
            record: record,
            priority: priority) {
            return mainActorContinuation
        }

        // The exact explicit-MainActor signature may unlock only the complete
        // confined continuation above. It must not borrow source-call or
        // snapshot-kernel routes when imported identity is absent.
        guard !closure.isPhysicalExplicitMainActorContinuationCandidate else {
            return nil
        }

        if let sourceCall = try physicalConfinedSourceCallJob(
            expression,
            closure: closure,
            entry: entry,
            record: record,
            priority: priority) {
            return sourceCall
        }

        // A modeled `[self] in` or `[weak self] in` signature may unlock only
        // the confined source call above. It must not broaden literal or
        // value-snapshot kernels.
        guard closure.isPhysicalSnapshotKernelCandidate else {
            return nil
        }

        let capability: RuntimeWorkerCapability
        let kernel: RuntimeSourceSnapshotKernel
        if isTaskYield(expression, closure: closure) {
            capability = try entry.makeWorkerCapability(copying: [])
            kernel = .taskYield
        } else if let value = literalWorkerSnapshot(expression) {
            capability = try entry.makeWorkerCapability(copying: [])
            kernel = .constant(value)
        } else if let lowered = try capturedImmutableStringCountKernel(
            expression, closure: closure, entry: entry) {
            capability = lowered.capability
            kernel = lowered.kernel
        } else if let lowered = try capturedImmutableStringArrayCountKernel(
            expression, closure: closure, entry: entry) {
            capability = lowered.capability
            kernel = lowered.kernel
        } else if let lowered = try capturedImmutableStringDistanceKernel(
            expression, closure: closure, entry: entry) {
            capability = lowered.capability
            kernel = lowered.kernel
        } else if let lowered = try capturedImmutableBooleanConditionalSleepKernel(
            expression, closure: closure, entry: entry) {
            capability = lowered.capability
            kernel = lowered.kernel
        } else {
            return nil
        }
        return RuntimePhysicalSourceKernelJob(
            workerJob: RuntimePhysicalWorkerJob(
                capability: capability,
                priority: priority
            ) { capability in
                try await kernel.execute(with: capability)
            },
            cancellationBehavior: kernel.cancellationBehavior,
            permitLifetime: .operation)
    }

    /// FreeChat, Provenance, and Planet use detached bodies whose first
    /// statement is a contained throwing sleep and whose second statement
    /// re-enters application code. Execute only the exact demand-proven
    /// core-Task sleep on a worker. The suffix remains a MainActor-confined
    /// closure owned by RuntimeTaskRecord, and its complete RuntimeValue/Error
    /// outcome is redeemed by the logical task after the worker returns a
    /// Sendable completion token.
    private func physicalTryOptionalSleepPrefixJob(
        closure: ClosureValue,
        entry: RuntimeEntry,
        record: RuntimeTaskRecord,
        priority: RuntimeTaskPriority
    ) throws -> RuntimePhysicalSourceKernelJob? {
        guard closure.body.count == 2,
              let first = closure.body.first,
              let firstExpression = Self.singleExpression(in: first),
              let attempt = firstExpression.as(TryExprSyntax.self),
              attempt.questionOrExclamationMark?.text == "?",
              let awaitExpression = attempt.expression
                .as(AwaitExprSyntax.self),
              let sleepCall = awaitExpression.expression
                .as(FunctionCallExprSyntax.self),
              sleepCall.trailingClosure == nil,
              sleepCall.additionalTrailingClosures.isEmpty,
              resolvesCoreTaskCall(
                sleepCall, named: "sleep", closure: closure),
              Array(sleepCall.arguments).count == 1,
              let sleepArgument = sleepCall.arguments.first,
              let suffixItem = closure.body.last,
              case .expr(let suffixExpression) = suffixItem.item,
              suffixExpression.is(AwaitExprSyntax.self),
              record.entry === entry,
              record.physicalSourceCall == nil,
              record.physicalSourceContinuation == nil,
              closure.programPlan === entry.programPlan else {
            return nil
        }

        let sleepKernel: RuntimeSourceSnapshotKernel
        if (closure.isPhysicalSnapshotKernelCandidate
            || closure.isPhysicalWeakSelfSourceCallCandidate),
           sleepArgument.label?.text == "for",
           let duration = sourceSnapshotSleepDuration(
               sleepArgument.expression) {
            sleepKernel = .taskSleep(.constant(duration))
        } else if (closure.isPhysicalSnapshotKernelCandidate
                    || closure.isPhysicalWeakSelfSourceCallCandidate),
                  sleepArgument.label?.text == "nanoseconds",
                  let nanoseconds = sourceSnapshotNanosecondsLiteral(
                      sleepArgument.expression) {
            sleepKernel = .taskSleepNanoseconds(nanoseconds)
        } else {
            return nil
        }

        let suffix = ClosureValue(
            parameters: [],
            body: CodeBlockItemListSyntax(Array(closure.body.dropFirst())),
            captured: closure.captured,
            isBuilder: false,
            returnType: closure.returnType,
            returnTypeName: closure.returnTypeName,
            programMetadata: closure.programMetadata,
            programPlan: closure.programPlan)
        suffix.extensionFrame = closure.extensionFrame
        suffix.functionDeclID = closure.functionDeclID
        suffix.lexicalOwner = closure.lexicalOwner
        suffix.genericParameters = closure.genericParameters
        suffix.debugName = closure.debugName.map {
            "\($0) [physical sleep continuation]"
        }
        suffix.sourceFunctionName = closure.sourceFunctionName
        suffix.executorPreference = closure.executorPreference
        suffix.globalActorAttributeCandidates =
            closure.globalActorAttributeCandidates
        suffix.isExplicitlyNonisolated = closure.isExplicitlyNonisolated
        suffix.lexicalExecutor = closure.lexicalExecutor
        suffix.programState = closure.programState
        suffix.sourceFunctionTargetDescriptor =
            closure.sourceFunctionTargetDescriptor

        let capability = try entry.makeWorkerCapability(copying: [])
        let command = RuntimePhysicalSourceContinuationCommand(
            entryID: entry.id,
            taskID: record.id)
        let handoff = RuntimePhysicalSourceExecutorHandoff()
        let relay = concurrencyRuntime.sourceContinuationReentryRelay
        record.physicalSourceContinuation =
            RuntimeRegisteredPhysicalSourceContinuation(
                command: command,
                suffix: suffix)

        return RuntimePhysicalSourceKernelJob(
            workerJob: RuntimePhysicalWorkerJob(
                capability: capability,
                priority: priority
            ) { capability in
                do {
                    _ = try await sleepKernel.execute(with: capability)
                } catch is CancellationError {
                    // This is the exact authored `try?` boundary. Cancellation
                    // remains visible to the confined suffix through the
                    // logical EvaluationTaskContext and native source task.
                }
                return try await relay.invoke(
                    command,
                    capability: capability,
                    handoff: handoff)
            },
            cancellationBehavior: .observed,
            permitLifetime: .untilConfinedExecutorEntry(handoff),
            confinedContinuationCommand: command)
    }

    /// Planet launches detached operations that either contain one imported
    /// `MainActor.run(body:)` expression or carry the exact `@MainActor in`
    /// signature. The worker performs only physical launch and executor
    /// handoff. The source closure, captures, MainActor body, and complete
    /// outcome remain in the continuation record used by sleep-prefix jobs.
    private func physicalMainActorContinuationJob(
        _ expression: ExprSyntax,
        closure: ClosureValue,
        entry: RuntimeEntry,
        record: RuntimeTaskRecord,
        priority: RuntimeTaskPriority
    ) throws -> RuntimePhysicalSourceKernelJob? {
        let isSignatureFreeRun = closure.isPhysicalSnapshotKernelCandidate
            && isImportedMainActorRun(expression, closure: closure)
        let isExplicitMainActorClosure = closure
            .isPhysicalExplicitMainActorContinuationCandidate
            && hasImportedMainActorIdentity(closure)
        guard isSignatureFreeRun || isExplicitMainActorClosure,
              record.entry === entry,
              record.physicalSourceCall == nil,
              record.physicalSourceContinuation == nil,
              closure.programPlan === entry.programPlan else {
            return nil
        }

        let capability = try entry.makeWorkerCapability(copying: [])
        let command = RuntimePhysicalSourceContinuationCommand(
            entryID: entry.id,
            taskID: record.id)
        let handoff = RuntimePhysicalSourceExecutorHandoff()
        let relay = concurrencyRuntime.sourceContinuationReentryRelay
        record.physicalSourceContinuation =
            RuntimeRegisteredPhysicalSourceContinuation(
                command: command,
                suffix: closure)

        return RuntimePhysicalSourceKernelJob(
            workerJob: RuntimePhysicalWorkerJob(
                capability: capability,
                priority: priority
            ) { capability in
                try await relay.invoke(
                    command,
                    capability: capability,
                    handoff: handoff)
            },
            // Neither MainActor.run nor explicit actor isolation suppresses
            // body entry on cancellation. Preserve the source task's logical
            // bit without cancelling the infrastructure wrapper first.
            cancellationBehavior: .unobserved,
            permitLifetime: .untilConfinedExecutorEntry(handoff),
            confinedContinuationCommand: command)
    }

    /// Imported nominal identity, not source spelling, admits either worker
    /// wrapper. An active source/local `MainActor` binding therefore keeps the
    /// same call or closure annotation on the cooperative evaluator.
    private func isImportedMainActorRun(
        _ expression: ExprSyntax,
        closure: ClosureValue
    ) -> Bool {
        guard let awaitExpression = expression.as(AwaitExprSyntax.self),
              let call = awaitExpression.expression
                .as(FunctionCallExprSyntax.self),
              call.arguments.isEmpty,
              call.trailingClosure != nil,
              call.additionalTrailingClosures.isEmpty,
              let member = call.calledExpression
                .as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "run",
              member.declName.argumentNames == nil,
              let reference = member.base?
                .as(DeclReferenceExprSyntax.self),
              reference.baseName.text == "MainActor",
              reference.argumentNames == nil,
              GeneratedConcurrencySurface.nominalMemberIntrinsic(
                typeName: "MainActor",
                memberName: "run") == .mainActorRun else {
            return false
        }

        return hasImportedMainActorIdentity(closure)
    }

    private func hasImportedMainActorIdentity(
        _ closure: ClosureValue
    ) -> Bool {
        guard let selected = closure.captured.lookup("MainActor") else {
            // Imported nominals are materialized lazily as HostTypeMarker;
            // absence here proves no lexical/source binding shadows it.
            return true
        }
        guard case .host(let payload) = selected,
              let marker = payload as? HostTypeMarker else {
            return false
        }
        return marker.name == "MainActor"
    }

    /// A detached wrapper may have the complete body `await self.method(...)`
    /// or the demand-backed `try? await self.throwingMethod()` spelling. Admit
    /// only direct-self calls after runtime resolution proves one exact
    /// supported declaration route: an async source-class method on
    /// MainActor/@concurrent, or one of the checked default-actor shapes below.
    /// The physical worker carries only a command and checked argument
    /// snapshots; RuntimeTaskRecord retains the selected receiver closure on
    /// MainActor.
    private func physicalConfinedSourceCallJob(
        _ expression: ExprSyntax,
        closure: ClosureValue,
        entry: RuntimeEntry,
        record: RuntimeTaskRecord,
        priority: RuntimeTaskPriority
    ) throws -> RuntimePhysicalSourceKernelJob? {
        let awaitExpression: AwaitExprSyntax
        let errorDisposition: RuntimePhysicalSourceCallErrorDisposition
        if let directAwait = expression.as(AwaitExprSyntax.self) {
            awaitExpression = directAwait
            errorDisposition = .propagate
        } else if let attempt = expression.as(TryExprSyntax.self),
                  attempt.questionOrExclamationMark?.text == "?",
                  let optionalAwait = attempt.expression
                    .as(AwaitExprSyntax.self) {
            awaitExpression = optionalAwait
            errorDisposition = .suppressToOptional
        } else {
            return nil
        }
        guard let call = awaitExpression.expression
                .as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty else {
            return nil
        }
        let metadata = closure.programMetadata?.callSiteMetadataIndex
            .metadata(for: call) ?? ParsedCallSiteMetadata(call)
        guard metadata.callee.shape == .explicitMember,
              let name = metadata.callee.name,
              let member = metadata.callee.member,
              member.declName.argumentNames == nil,
              let selfBox = closure.captured.box(
                for: "self", before: globals) else {
            return nil
        }

        let instance: Instance
        let isWeakOptionalSelf: Bool
        if let receiver = member.base?.as(DeclReferenceExprSyntax.self),
           receiver.baseName.text == "self",
           receiver.argumentNames == nil,
           case .instance(let directInstance) = try selfBox.load() {
            instance = directInstance
            isWeakOptionalSelf = false
        } else if closure.isPhysicalWeakSelfSourceCallCandidate,
                  selfBox.referenceOwnership == .weak,
                  let optional = member.base?
                    .as(OptionalChainingExprSyntax.self),
                  let receiver = optional.expression
                    .as(DeclReferenceExprSyntax.self),
                  receiver.baseName.text == "self",
                  receiver.argumentNames == nil,
                  case .some(.instance(let weakInstance), _) =
                    try selfBox.load().optionalState {
            instance = weakInstance
            isWeakOptionalSelf = true
        } else {
            return nil
        }

        guard record.entry === entry,
              record.physicalSourceCall == nil,
              closure.programPlan === entry.programPlan,
              let loweredArguments = try physicalSourceCallArguments(
                metadata.arguments,
                closure: closure),
              let target = resolveOwnSourceInstanceMethodCallTarget(
                named: name,
                on: instance,
                arguments: loweredArguments.callArguments),
              target.closure.parameters.count
                == loweredArguments.commandArguments.count,
              zip(
                target.closure.parameters,
                loweredArguments.commandArguments
              ).allSatisfy({ parameter, argument in
                  !parameter.isVariadic
                    && !parameter.isBuilderAttributed
                    && !parameter.isIsolated
                    && argument.valueKind.accepts(
                        parameterTypeName: parameter.typeName)
              }),
              target.descriptor.originProgramPlan === entry.programPlan else {
            return nil
        }
        let isSupportedRoute: Bool
        switch errorDisposition {
        case .propagate:
            guard !target.descriptor.isThrowing else { return nil }
            isSupportedRoute = isWeakOptionalSelf
                ? isSupportedPhysicalWeakSourceCallRoute(
                    target.descriptor,
                    on: instance,
                    parameters: target.closure.parameters,
                    arguments: loweredArguments.commandArguments)
                : isSupportedPhysicalSourceCallRoute(
                    target.descriptor,
                    on: instance,
                    parameters: target.closure.parameters,
                    arguments: loweredArguments.commandArguments)
        case .suppressToOptional:
            guard !isWeakOptionalSelf else { return nil }
            isSupportedRoute = isSupportedPhysicalTryOptionalSourceCallRoute(
                target.descriptor,
                on: instance,
                parameters: target.closure.parameters,
                arguments: loweredArguments.commandArguments)
        }
        guard isSupportedRoute else { return nil }

        let resultKind: RuntimePhysicalSourceCallResultKind
        if errorDisposition == .suppressToOptional {
            resultKind = .optionalVoid
        } else if isWeakOptionalSelf {
            // A weak wrapper always returns Void?. Its dedicated route proof
            // above owns the exact target/argument surface, while the receiver
            // is resolved again only after confined re-entry.
            resultKind = .optionalVoid
        } else {
            guard let directResultKind = RuntimePhysicalSourceCallResultKind(
                returnTypeName: target.descriptor.returnTypeName) else {
                return nil
            }
            resultKind = directResultKind
        }

        let capability = try entry.makeWorkerCapability(
            copying: loweredArguments.sourceBindings)
        let handoff = RuntimePhysicalSourceExecutorHandoff()
        let command = RuntimePhysicalSourceCallCommand(
            entryID: entry.id,
            taskID: record.id,
            target: target.descriptor,
            arguments: loweredArguments.commandArguments,
            resultKind: resultKind,
            errorDisposition: errorDisposition)
        let relay = concurrencyRuntime.sourceCallReentryRelay
        let invocation: RuntimeRegisteredPhysicalSourceCallInvocation =
            isWeakOptionalSelf
                ? .weakSelfOptional(
                    sourceClosure: closure,
                    methodName: name)
                : .resolved(target)
        record.physicalSourceCall = RuntimeRegisteredPhysicalSourceCall(
            command: command,
            invocation: invocation)
        return RuntimePhysicalSourceKernelJob(
            workerJob: RuntimePhysicalWorkerJob(
                capability: capability,
                priority: priority
            ) { capability in
                try await relay.invoke(
                    command,
                    capability: capability,
                    handoff: handoff)
            },
            // Source cancellation remains a logical runtime fact observed by
            // the reinstated EvaluationTaskContext. It must not become an
            // infrastructure cancellation that suppresses method entry.
            cancellationBehavior: .unobserved,
            permitLifetime: .untilConfinedExecutorEntry(handoff))
    }

    /// Keep the physical route table demand-scoped and fail closed. A source
    /// actor's synchronous method is still an asynchronous cross-actor call:
    /// confined re-entry invokes it through the ordinary suspending evaluator,
    /// which acquires that exact actor mailbox before touching actor storage.
    /// Async actor routes own either one required integer argument or one
    /// explicitly supplied Boolean for a defaulted parameter. Other argument
    /// families, String results, explicitly nonisolated methods, and custom
    /// actor executors remain cooperative until separately proven. A plain
    /// async source-class method may inherit the detached caller for the
    /// demand-backed argument-free Void route or Planet's single immutable
    /// String-capture Void route; explicit nonisolated methods and richer
    /// inherited signatures remain cooperative.
    private func isSupportedPhysicalSourceCallRoute(
        _ target: RuntimeSourceFunctionTargetDescriptor,
        on instance: Instance,
        parameters: [ClosureValue.Parameter],
        arguments: [RuntimePhysicalSourceCallArgument]
    ) -> Bool {
        switch target.lexicalPlacement {
        case .lexicalType(_, isTypeMember: false, isActor: false):
            guard !instance.symbol.isActor,
                  target.isAsync,
                  parameters.allSatisfy({ $0.defaultValue == nil }) else {
                return false
            }
            switch target.isolation {
            case .executor(.mainActor),
                 .executor(.cooperativeDefault):
                // String-family arguments are demand-scoped to inherited
                // routes below. Existing MainActor/@concurrent direct routes
                // retain their integer/Boolean argument surface.
                return !arguments.contains { $0.valueKind.isStringFamily }
            case .lazyGlobalActorCandidates(let candidates):
                return parameters.isEmpty
                    && arguments.isEmpty
                    && RuntimePhysicalSourceCallResultKind(
                        returnTypeName: target.returnTypeName) == .void
                    && hasUniqueDefaultSourceGlobalActorCandidate(candidates)
            case .inherited:
                guard RuntimePhysicalSourceCallResultKind(
                    returnTypeName: target.returnTypeName) == .void else {
                    return false
                }
                let isArgumentFreeRoute = parameters.isEmpty
                    && arguments.isEmpty
                let isSingleStringRoute = parameters.count == 1
                    && arguments.count == 1
                    && arguments[0].valueKind == .string
                    && arguments[0].origin == .capturedImmutable
                return isArgumentFreeRoute || isSingleStringRoute
            case .explicitlyNonisolated,
                 .executor(.detached),
                 .executor(.actor):
                return false
            }

        case .lexicalType(_, isTypeMember: false, isActor: true):
            guard instance.symbol.isActor,
                  !instance.symbol.requiresCustomExecutorDispatch,
                  RuntimePhysicalSourceCallResultKind(
                    returnTypeName: target.returnTypeName) == .void,
                  let actorID = instance.actorID else {
                return false
            }
            let isSynchronousVoidRoute = !target.isAsync
                && parameters.isEmpty
                && arguments.isEmpty
            let isAsyncIntegerVoidRoute = target.isAsync
                && parameters.allSatisfy({ $0.defaultValue == nil })
                && arguments.count == 1
                && arguments[0].valueKind == .integer
            let isAsyncDefaultedBooleanVoidRoute = target.isAsync
                && parameters.count == 1
                && parameters[0].defaultValue != nil
                && arguments.count == 1
                && arguments[0].valueKind == .boolean
            guard isSynchronousVoidRoute
                    || isAsyncIntegerVoidRoute
                    || isAsyncDefaultedBooleanVoidRoute else {
                return false
            }
            return target.isolation == .executor(.actor(actorID))

        case .global,
             .lexicalType(_, isTypeMember: true, isActor: _):
            return false
        }
    }

    /// Meshtastic's exact argument-free `try? await self.method()` wrapper is
    /// the first throwing source-call route. Containment is part of admission:
    /// only an own inherited-isolation async throwing Void source-class method
    /// may use it, and the relay optionalizes the outcome before any worker
    /// boundary is crossed.
    private func isSupportedPhysicalTryOptionalSourceCallRoute(
        _ target: RuntimeSourceFunctionTargetDescriptor,
        on instance: Instance,
        parameters: [ClosureValue.Parameter],
        arguments: [RuntimePhysicalSourceCallArgument]
    ) -> Bool {
        guard case .lexicalType(
                _, isTypeMember: false, isActor: false
              ) = target.lexicalPlacement,
              !instance.symbol.isActor,
              target.isAsync,
              target.isThrowing,
              target.isolation == .inherited,
              RuntimePhysicalSourceCallResultKind(
                returnTypeName: target.returnTypeName) == .void else {
            return false
        }
        return parameters.isEmpty && arguments.isEmpty
    }

    /// Weak optional-self admission is deliberately separate from direct-self
    /// routing. Provenance owns the inherited argument-free and String-literal
    /// forms; Session adds one immutable String capture to that same inherited
    /// route, KeyboardCowboy adds one immutable `[String]` capture, and
    /// Amperfy owns the captured-String `@concurrent` form. No weak receiver or
    /// source argument crosses the worker boundary: only checked copied
    /// snapshots do.
    private func isSupportedPhysicalWeakSourceCallRoute(
        _ target: RuntimeSourceFunctionTargetDescriptor,
        on instance: Instance,
        parameters: [ClosureValue.Parameter],
        arguments: [RuntimePhysicalSourceCallArgument]
    ) -> Bool {
        guard case .lexicalType(
                _, isTypeMember: false, isActor: false
              ) = target.lexicalPlacement,
              !instance.symbol.isActor,
              target.isAsync,
              parameters.allSatisfy({ $0.defaultValue == nil }),
              RuntimePhysicalSourceCallResultKind(
                returnTypeName: target.returnTypeName) == .void else {
            return false
        }
        switch target.isolation {
        case .inherited:
            let isArgumentFreeRoute = parameters.isEmpty && arguments.isEmpty
            let hasSupportedStringOrigin = arguments.count == 1
                && (arguments[0].origin == .literal
                    || arguments[0].origin == .capturedImmutable)
            let isSingleStringRoute = parameters.count == 1
                && arguments.count == 1
                && arguments[0].valueKind == .string
                && hasSupportedStringOrigin
            let isCapturedStringArrayRoute = parameters.count == 1
                && arguments.count == 1
                && arguments[0].valueKind == .stringArray
                && arguments[0].origin == .capturedImmutable
            return isArgumentFreeRoute
                || isSingleStringRoute
                || isCapturedStringArrayRoute
        case .executor(.cooperativeDefault):
            return parameters.count == 1
                && arguments.count == 1
                && arguments[0].valueKind == .string
                && arguments[0].origin == .capturedImmutable
        case .explicitlyNonisolated,
             .lazyGlobalActorCandidates,
             .executor(.mainActor),
             .executor(.detached),
             .executor(.actor):
            return false
        }
    }

    /// Prove declaration provenance without touching `static shared` during
    /// physical admission. Resolving that member can initialize source state,
    /// so ordinary confined invocation remains the only place that may do it.
    /// The first demand-backed route accepts only a source global actor whose
    /// nominal is itself a default-executor actor; struct/enum wrappers and
    /// custom executors remain cooperative until separately evidenced.
    private func hasUniqueDefaultSourceGlobalActorCandidate(
        _ candidates: [String]
    ) -> Bool {
        var matchedSymbols: Set<ObjectIdentifier> = []
        for candidate in Set(candidates) {
            guard case .type(let symbol) = globals.lookup(candidate),
                  symbol.attributeNames.contains("globalActor"),
                  symbol.isActor,
                  !symbol.requiresCustomExecutorDispatch else {
                continue
            }
            matchedSymbols.insert(ObjectIdentifier(symbol))
        }
        return matchedSymbols.count == 1
    }

    /// Evaluate no source effects while admitting a physical wrapper. An
    /// integer, Boolean, or demand-cited String literal is already a value,
    /// and a direct immutable Int/Int64, String, or demand-cited `[String]`
    /// capture has fixed value semantics for this closure. Every other
    /// argument spelling and type stays on the cooperative evaluator.
    /// The checked capability performs the structural Sendable copy; the
    /// command retains labels, binding IDs, and the expected value kind.
    private func physicalSourceCallArguments(
        _ metadata: [ParsedCallArgumentMetadata],
        closure: ClosureValue
    ) throws -> (
        callArguments: CallArguments,
        sourceBindings: [RuntimeWorkerSourceBinding],
        commandArguments: [RuntimePhysicalSourceCallArgument]
    )? {
        var callArguments: [CallArguments.Argument] = []
        var sourceBindings: [RuntimeWorkerSourceBinding] = []
        var commandArguments: [RuntimePhysicalSourceCallArgument] = []
        callArguments.reserveCapacity(metadata.count)
        sourceBindings.reserveCapacity(metadata.count)
        commandArguments.reserveCapacity(metadata.count)

        for (index, argument) in metadata.enumerated() {
            guard argument.trailingClosure == nil,
                  !argument.isTrailing else {
                return nil
            }

            let value: RuntimeValue
            let valueKind: RuntimePhysicalSourceCallValueKind
            let origin: RuntimePhysicalSourceCallArgumentOrigin
            if let snapshot = literalWorkerSnapshot(argument.expression) {
                switch snapshot {
                case .int:
                    valueKind = .integer
                case .bool:
                    valueKind = .boolean
                case .string:
                    valueKind = .string
                default:
                    return nil
                }
                origin = .literal
                value = snapshot.materializedRuntimeValue()
            } else if let reference = argument.expression
                .as(DeclReferenceExprSyntax.self),
                      reference.argumentNames == nil,
                      let box = closure.captured.locallyOwnedBox(
                        for: reference.baseName.text),
                      !box.isMutableBinding {
                value = try box.load()
                guard let snapshot = try? RuntimeWorkerValueSnapshot.copying(
                    value,
                    path: "argument[\(index)]") else {
                    return nil
                }
                switch snapshot {
                case .int:
                    valueKind = .integer
                case .string:
                    valueKind = .string
                case .array(let values) where values.allSatisfy({ value in
                    if case .string = value { return true }
                    return false
                }):
                    valueKind = .stringArray
                default:
                    return nil
                }
                origin = .capturedImmutable
            } else {
                return nil
            }

            let bindingName = "$argument\(index)"
            callArguments.append(.init(
                label: argument.label,
                value: value))
            sourceBindings.append(RuntimeWorkerSourceBinding(
                name: bindingName,
                value: value))
            commandArguments.append(RuntimePhysicalSourceCallArgument(
                label: argument.label,
                bindingName: bindingName,
                valueKind: valueKind,
                origin: origin))
        }

        return (
            CallArguments(arguments: callArguments),
            sourceBindings,
            commandArguments)
    }

    /// TCA's TestStore uses exactly
    /// `Task.detached(priority: .background) { await Task.yield() }.value`.
    /// Admit only the zero-argument standard-library call. The worker receives
    /// a typed command and an empty capability, never this syntax tree.
    private func isTaskYield(
        _ expression: ExprSyntax,
        closure: ClosureValue
    ) -> Bool {
        guard let awaitExpression = expression.as(AwaitExprSyntax.self),
              let call = awaitExpression.expression
                .as(FunctionCallExprSyntax.self),
              call.arguments.isEmpty,
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty,
              resolvesCoreTaskCall(
                call, named: "yield", closure: closure) else {
            return false
        }
        return true
    }

    /// Raw spelling is not a call target. A source value or type named
    /// `Task` may legally shadow the standard-library type, so physical
    /// lowering requires the exact registered builtin capability reachable
    /// from the closure's lexical environment. The immutable call-site index
    /// supplies syntax shape; runtime identity supplies the selected value.
    private func resolvesCoreTaskCall(
        _ call: FunctionCallExprSyntax,
        named expectedName: String,
        closure: ClosureValue
    ) -> Bool {
        let metadata = closure.programMetadata?.callSiteMetadataIndex
            .metadata(for: call) ?? ParsedCallSiteMetadata(call)
        guard metadata.callee.shape == .explicitMember,
              metadata.callee.name == expectedName,
              let member = metadata.callee.member,
              member.declName.argumentNames == nil,
              let reference = member.base?
                .as(DeclReferenceExprSyntax.self),
              reference.baseName.text == "Task",
              reference.argumentNames == nil,
              case .hostFunction(let function)? =
                closure.captured.lookup(reference.baseName.text),
              coreFunctionIntrinsic(for: function) == .taskType else {
            return false
        }
        return true
    }

    /// CotEditor's `EditorCounter` executes `Task.detached { string.count }`
    /// over a local immutable String. Preserve that construct without moving
    /// its Box or Environment: prove the source binding is a `let`, copy its
    /// value while still on MainActor, then lower only the typed count node.
    private func capturedImmutableStringCountKernel(
        _ expression: ExprSyntax,
        closure: ClosureValue,
        entry: RuntimeEntry
    ) throws -> (
        capability: RuntimeWorkerCapability,
        kernel: RuntimeSourceSnapshotKernel
    )? {
        guard let member = expression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "count",
              member.declName.argumentNames == nil,
              let reference = member.base?.as(DeclReferenceExprSyntax.self),
              reference.argumentNames == nil,
              let programState = closure.programState,
              programState.propertyTargetIdentity(for: .stringCount)
                == .standardLibrary(.stringCount) else {
            return nil
        }
        let name = reference.baseName.text
        guard let box = closure.captured.locallyOwnedBox(for: name),
              !box.isMutableBinding,
              case .string(let value) = try box.load() else {
            return nil
        }

        let capability = try entry.makeWorkerCapability(copying: [
            RuntimeWorkerSourceBinding(name: name, value: .string(value)),
        ])
        guard capability.bindings.count == 1,
              capability.bindings[0].name == name,
              case .string = capability.bindings[0].value else {
            throw RuntimeError(message:
                "physical String.count kernel produced an invalid snapshot")
        }
        return (
            capability,
            .expression(.stringCount(.binding(name))))
    }

    /// CotEditor's selection counter executes
    /// `Task.detached { selectedStrings.map(\.count).reduce(0, +) }` over a
    /// local immutable array. Lower that exact demand-cited spelling to a
    /// recursively copied array snapshot and typed reduction node. Alternate
    /// map/reduce spellings and every mutable/global binding remain confined.
    private func capturedImmutableStringArrayCountKernel(
        _ expression: ExprSyntax,
        closure: ClosureValue,
        entry: RuntimeEntry
    ) throws -> (
        capability: RuntimeWorkerCapability,
        kernel: RuntimeSourceSnapshotKernel
    )? {
        guard let reduceCall = expression.as(FunctionCallExprSyntax.self),
              reduceCall.trailingClosure == nil,
              reduceCall.additionalTrailingClosures.isEmpty,
              let reduceMember = reduceCall.calledExpression
                .as(MemberAccessExprSyntax.self),
              reduceMember.declName.baseName.text == "reduce",
              reduceMember.declName.argumentNames == nil,
              let mapCall = reduceMember.base?
                .as(FunctionCallExprSyntax.self),
              mapCall.trailingClosure == nil,
              mapCall.additionalTrailingClosures.isEmpty,
              let mapMember = mapCall.calledExpression
                .as(MemberAccessExprSyntax.self),
              mapMember.declName.baseName.text == "map",
              mapMember.declName.argumentNames == nil,
              let reference = mapMember.base?
                .as(DeclReferenceExprSyntax.self),
              reference.argumentNames == nil,
              let programState = closure.programState,
              programState.methodTargetProof(for: .arrayMap)
                == .standardLibrary(.arrayMap),
              programState.methodTargetProof(for: .arrayReduce)
                == .standardLibrary(.arrayReduce),
              programState.propertyTargetIdentity(for: .substringCount)
                == .standardLibrary(.substringCount) else {
            return nil
        }

        let reduceArguments = Array(reduceCall.arguments)
        let mapArguments = Array(mapCall.arguments)
        guard reduceArguments.count == 2,
              reduceArguments.allSatisfy({ $0.label == nil }),
              reduceArguments[0].expression.trimmedDescription == "0",
              reduceArguments[1].expression.trimmedDescription == "+",
              mapArguments.count == 1,
              mapArguments[0].label == nil,
              let keyPath = mapArguments[0].expression
                .as(KeyPathExprSyntax.self),
              keyPath.trimmedDescription == #"\.count"# else {
            return nil
        }

        let name = reference.baseName.text
        guard let box = closure.captured.locallyOwnedBox(for: name),
              !box.isMutableBinding,
              RuntimeDeclaredType.nominalTypeName(
                RuntimeDeclaredType.arrayElementTypeName(
                    in: box.declaredTypeName)) == "Substring",
              case .array(let values) = try box.load(),
              values.allSatisfy({
                  if case .string = $0 { return true }
                  return false
              }) else {
            return nil
        }

        let capability = try entry.makeWorkerCapability(copying: [
            RuntimeWorkerSourceBinding(name: name, value: .array(values)),
        ])
        guard capability.bindings.count == 1,
              capability.bindings[0].name == name,
              case .array(let copiedValues) = capability.bindings[0].value,
              copiedValues.allSatisfy({
                  if case .string = $0 { return true }
                  return false
              }) else {
            throw RuntimeError(message:
                "physical String-count reduction produced an invalid snapshot")
        }
        return (
            capability,
            .expression(.stringCountSum(.binding(name))))
    }

    /// CotEditor's selection counter executes
    /// `string.distance(from: string.startIndex, to: location)` over a local
    /// immutable String and an index derived from that value. Copy both
    /// checked-Sendable values and lower only the exact standard-library
    /// expression; alternate bounds or mutable/global bindings stay confined.
    private func capturedImmutableStringDistanceKernel(
        _ expression: ExprSyntax,
        closure: ClosureValue,
        entry: RuntimeEntry
    ) throws -> (
        capability: RuntimeWorkerCapability,
        kernel: RuntimeSourceSnapshotKernel
    )? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty,
              let member = call.calledExpression
                .as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "distance",
              member.declName.argumentNames == nil,
              let stringReference = member.base?
                .as(DeclReferenceExprSyntax.self),
              stringReference.argumentNames == nil,
              let programState = closure.programState,
              programState.methodTargetProof(for: .stringDistanceFromTo)
                == .standardLibrary(.stringDistanceFromTo) else {
            return nil
        }

        let arguments = Array(call.arguments)
        guard arguments.count == 2,
              arguments[0].label?.text == "from",
              arguments[1].label?.text == "to",
              let startIndex = arguments[0].expression
                .as(MemberAccessExprSyntax.self),
              startIndex.declName.baseName.text == "startIndex",
              startIndex.declName.argumentNames == nil,
              let startBase = startIndex.base?
                .as(DeclReferenceExprSyntax.self),
              startBase.argumentNames == nil,
              startBase.baseName.text == stringReference.baseName.text,
              let indexReference = arguments[1].expression
                .as(DeclReferenceExprSyntax.self),
              indexReference.argumentNames == nil else {
            return nil
        }

        let stringName = stringReference.baseName.text
        let indexName = indexReference.baseName.text
        guard stringName != indexName,
              let stringBox = closure.captured.locallyOwnedBox(
                for: stringName),
              !stringBox.isMutableBinding,
              case .string(let string) = try stringBox.load(),
              let indexBox = closure.captured.locallyOwnedBox(for: indexName),
              !indexBox.isMutableBinding,
              case .host(let payload) = try indexBox.load(),
              let index = payload as? String.Index else {
            return nil
        }

        let capability = try entry.makeWorkerCapability(copying: [
            RuntimeWorkerSourceBinding(
                name: stringName, value: .string(string)),
            RuntimeWorkerSourceBinding(
                name: indexName, value: .native(index)),
        ])
        guard capability.bindings.count == 2,
              capability.bindings[0].name == stringName,
              case .string = capability.bindings[0].value,
              capability.bindings[1].name == indexName,
              case .stringIndex = capability.bindings[1].value else {
            throw RuntimeError(message:
                "physical String.distance kernel produced invalid snapshots")
        }
        let stringExpression = RuntimeSourceSnapshotExpression.binding(
            stringName)
        return (
            capability,
            .expression(.stringDistance(
                stringExpression,
                from: .stringStartIndex(stringExpression),
                to: .binding(indexName))))
    }

    /// Signal-iOS executes a throwing `Task.sleep(for:)` whose duration is
    /// selected from an immutable Bool parameter. Admit only that exact
    /// standard-library shape, copy the Bool, and lower the two finite
    /// Duration literals to typed IR. Mutable/global conditions, other units,
    /// and alternate sleep overloads stay on the cooperative evaluator.
    private func capturedImmutableBooleanConditionalSleepKernel(
        _ expression: ExprSyntax,
        closure: ClosureValue,
        entry: RuntimeEntry
    ) throws -> (
        capability: RuntimeWorkerCapability,
        kernel: RuntimeSourceSnapshotKernel
    )? {
        guard let tryExpression = expression.as(TryExprSyntax.self),
              tryExpression.questionOrExclamationMark == nil,
              let awaitExpression = tryExpression.expression
                .as(AwaitExprSyntax.self),
              let sleepCall = awaitExpression.expression
                .as(FunctionCallExprSyntax.self),
              sleepCall.trailingClosure == nil,
              sleepCall.additionalTrailingClosures.isEmpty,
              resolvesCoreTaskCall(
                sleepCall, named: "sleep", closure: closure) else {
            return nil
        }

        let sleepArguments = Array(sleepCall.arguments)
        guard sleepArguments.count == 1,
              sleepArguments[0].label?.text == "for",
              let selection = sleepArguments[0].expression
                .as(TernaryExprSyntax.self),
              let conditionReference = selection.condition
                .as(DeclReferenceExprSyntax.self),
              conditionReference.argumentNames == nil,
              let trueDuration = sourceSnapshotSleepDuration(
                selection.thenExpression),
              let falseDuration = sourceSnapshotSleepDuration(
                selection.elseExpression) else {
            return nil
        }

        let conditionName = conditionReference.baseName.text
        guard let box = closure.captured.locallyOwnedBox(for: conditionName),
              !box.isMutableBinding,
              case .bool(let condition) = try box.load() else {
            return nil
        }

        let capability = try entry.makeWorkerCapability(copying: [
            RuntimeWorkerSourceBinding(
                name: conditionName, value: .bool(condition)),
        ])
        guard capability.bindings.count == 1,
              capability.bindings[0].name == conditionName,
              case .bool = capability.bindings[0].value else {
            throw RuntimeError(message:
                "physical conditional Task.sleep kernel produced an invalid snapshot")
        }
        return (
            capability,
            .taskSleep(.conditional(
                condition: .binding(conditionName),
                ifTrue: .constant(trueDuration),
                ifFalse: .constant(falseDuration))))
    }

    /// The cited call uses only `.seconds(Int)` and `.milliseconds(Int)`.
    /// Other Duration constructors remain cooperative until independently
    /// demand-cited and characterized.
    private func sourceSnapshotSleepDuration(
        _ expression: ExprSyntax
    ) -> RuntimeDuration? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty,
              let member = call.calledExpression
                .as(MemberAccessExprSyntax.self),
              member.base == nil,
              member.declName.argumentNames == nil else {
            return nil
        }
        let arguments = Array(call.arguments)
        guard arguments.count == 1,
              arguments[0].label == nil,
              let literal = arguments[0].expression
                .as(IntegerLiteralExprSyntax.self),
              let parsed = try? integerValue(of: literal),
              let amount = Int64(exactly: parsed),
              amount >= 0 else {
            return nil
        }

        let scale: Int64
        switch member.declName.baseName.text {
        case "seconds":
            scale = 1_000_000_000
        case "milliseconds":
            scale = 1_000_000
        default:
            return nil
        }
        let product = amount.multipliedReportingOverflow(by: scale)
        guard !product.overflow else { return nil }
        return .nanoseconds(product.partialValue)
    }

    /// Provenance's exact deprecated-era spelling supplies one nonnegative
    /// UInt64-compatible integer literal to `Task.sleep(nanoseconds:)`.
    /// Captured/computed values and the unlabeled deprecated overload remain
    /// cooperative until separately demand-cited.
    private func sourceSnapshotNanosecondsLiteral(
        _ expression: ExprSyntax
    ) -> UInt64? {
        guard let literal = expression.as(IntegerLiteralExprSyntax.self),
              let parsed = try? integerValue(of: literal),
              parsed >= 0 else {
            return nil
        }
        return UInt64(parsed)
    }

    private static func singleExpression(
        in item: CodeBlockItemSyntax
    ) -> ExprSyntax? {
        switch item.item {
        case .expr(let expression):
            return expression
        case .stmt(let statement):
            return statement.as(ReturnStmtSyntax.self)?.expression
        case .decl:
            return nil
        }
    }

    private func literalWorkerSnapshot(
        _ expression: ExprSyntax
    ) -> RuntimeWorkerValueSnapshot? {
        switch expression.kind {
        case .integerLiteralExpr:
            guard let value = try? integerValue(of:
                    expression.cast(IntegerLiteralExprSyntax.self)) else {
                return nil
            }
            return .int(value)
        case .floatLiteralExpr:
            let literal = expression.cast(FloatLiteralExprSyntax.self)
            guard let value = Double(
                literal.literal.text.filter { $0 != "_" }) else {
                return nil
            }
            return .double(value)
        case .booleanLiteralExpr:
            return .bool(expression.cast(BooleanLiteralExprSyntax.self)
                .literal.text == "true")
        case .nilLiteralExpr:
            return .nilValue
        case .stringLiteralExpr:
            guard let value = expression.cast(StringLiteralExprSyntax.self)
                    .representedLiteralValue else {
                return nil
            }
            return .string(value)
        default:
            return nil
        }
    }
}
