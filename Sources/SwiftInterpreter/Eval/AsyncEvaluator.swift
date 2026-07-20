import Foundation
import SwiftSyntax

/// Replaces suspension-bearing expression roots with values already produced
/// by the async evaluator. The rewritten eager expression then runs through
/// the mature synchronous machinery, so assignment, operators, casts,
/// subscripts, and host adoption retain one implementation.
nonisolated private final class SuspensionReplacementRewriter: SyntaxRewriter {
    let replacements: [SyntaxIdentifier: String]

    init(replacements: [SyntaxIdentifier: String]) {
        self.replacements = replacements
        super.init(viewMode: .sourceAccurate)
    }

    private func replacement(_ id: SyntaxIdentifier) -> ExprSyntax? {
        replacements[id].map {
            ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier($0)))
        }
    }

    override func visit(_ node: AwaitExprSyntax) -> ExprSyntax {
        replacement(node.id) ?? super.visit(node)
    }

    override func visit(_ node: TryExprSyntax) -> ExprSyntax {
        replacement(node.id) ?? super.visit(node)
    }

    override func visit(_ node: TernaryExprSyntax) -> ExprSyntax {
        replacement(node.id) ?? super.visit(node)
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> ExprSyntax {
        replacement(node.id) ?? super.visit(node)
    }

    override func visit(_ node: IfExprSyntax) -> ExprSyntax {
        replacement(node.id) ?? super.visit(node)
    }

    override func visit(_ node: SwitchExprSyntax) -> ExprSyntax {
        replacement(node.id) ?? super.visit(node)
    }

    /// A closure is a deferred body, not part of its surrounding expression's
    /// evaluation. Its awaits run when the closure itself is invoked.
    override func visit(_ node: ClosureExprSyntax) -> ExprSyntax {
        ExprSyntax(node)
    }
}

extension Interpreter {
    // MARK: - Suspension discovery and expression lowering

    private func syntaxContainsSuspension(_ syntax: Syntax) -> Bool {
        if syntax.is(ClosureExprSyntax.self) { return false }
        if syntax.is(AwaitExprSyntax.self) { return true }
        for child in syntax.children(viewMode: .sourceAccurate) {
            if syntaxContainsSuspension(child) { return true }
        }
        return false
    }

    /// Source-synchronous worker gateways need an internal suspension while
    /// the native operation crosses the bounded driver. Keep that transport
    /// opt-in: ordinary await-free calls continue through the mature eager
    /// evaluator. The first demand-backed source-helper subset is deliberately
    /// direct and non-transitive; nested closures and helper-call graphs remain
    /// confined until they receive their own target-resolution evidence.
    private func workerAdmissionValue(
        named name: String,
        in env: Environment
    ) -> RuntimeValue? {
        if let box = env.box(for: name, before: globals) {
            return box.value
        }
        if let box = globals.box(for: name) {
            return box.value
        }
        // Unknown uppercase identifiers use the interpreter's existing inert
        // imported-type marker. Never call `resolveIdentifier` from admission:
        // that could execute a computed or lazy source binding before the
        // ordinary evaluator reaches the expression.
        if name.first?.isUppercase == true {
            return .native(HostTypeMarker(name: name))
        }
        return nil
    }

    private func callDirectlyUsesWorkerHostOperation(
        _ call: FunctionCallExprSyntax,
        in env: Environment
    ) -> Bool {
        let metadata = callSiteMetadata(for: call).callee
        let callee: RuntimeValue?
        switch metadata.shape {
        case .directReference:
            guard let name = metadata.name else { return false }
            callee = workerAdmissionValue(named: name, in: env)

        case .explicitMember:
            guard let member = metadata.member else { return false }
            if hostStaticMemberChainUsesWorkerOperation(
                member, in: env) {
                return true
            }
            guard
                  let baseExpression = member.base,
                  let baseReference = baseExpression
                    .as(DeclReferenceExprSyntax.self) else {
                return false
            }
            guard let base = workerAdmissionValue(
                named: baseReference.baseName.text,
                in: env),
                  case .instance(let instance) = base else {
                return false
            }
            let name = instance.symbol.canonicalPropertyName(
                member.declName.baseName.text)
            // Admission must not read stored/lazy/computed callable storage.
            // The first helper subset is one unique source method; every
            // collision or overload stays on the eager confined path.
            guard instance.box(for: name) == nil,
                  instance.symbol.computedProperties[name] == nil,
                  let methods = instance.symbol.methods[name],
                  methods.count == 1,
                  let method = methods.first,
                  !activeFunctionBodies.contains(method.id),
                  let body = functionMetadata(for: method).body else {
                return false
            }
            callee = .closure(makeFunctionClosure(
                method,
                body: body,
                captured: instanceMethodEnvironment(instance)))

        case .implicitMember, .arrayType, .dictionaryType, .other:
            return false
        }

        switch callee {
        case .hostFunction(let function):
            return function.hasWorkerOperation
        case .closure(let closure):
            return closureDirectlyUsesWorkerHostOperation(closure)
        default:
            return false
        }
    }

    /// Recognize a statically named imported chain such as
    /// `FileManager.default.moveItem`. The registry supplies capability
    /// metadata without evaluating `default`; source types/values with the
    /// same root name are rejected by `workerAdmissionValue` before the
    /// registry is consulted.
    private func hostStaticMemberChainUsesWorkerOperation(
        _ member: MemberAccessExprSyntax,
        in env: Environment
    ) -> Bool {
        guard let receiver = member.base?.as(MemberAccessExprSyntax.self),
              let typeExpression = receiver.base,
              let typeReference = typeExpression
                .as(DeclReferenceExprSyntax.self),
              typeReference.argumentNames == nil,
              receiver.declName.argumentNames == nil,
              member.declName.argumentNames == nil,
              let root = workerAdmissionValue(
                named: typeReference.baseName.text, in: env),
              case .host(let payload) = root,
              let marker = payload as? HostTypeMarker else {
            return false
        }
        return registry?.hostMemberHasWorkerOperation(
            member.declName.baseName.text,
            onStaticMember: receiver.declName.baseName.text,
            ofType: marker.name) == true
    }

    private func closureDirectlyUsesWorkerHostOperation(
        _ closure: ClosureValue
    ) -> Bool {
        func visit(_ syntax: Syntax) -> Bool {
            // A nested declaration or closure is deferred and is not part of
            // this synchronous helper's dynamic execution.
            if syntax.is(ClosureExprSyntax.self)
                || syntax.as(DeclSyntax.self) != nil {
                return false
            }

            if let call = syntax.as(FunctionCallExprSyntax.self),
               let reference = call.calledExpression
                .as(DeclReferenceExprSyntax.self) {
                let value = workerAdmissionValue(
                    named: reference.baseName.text,
                    in: closure.captured)
                if case .hostFunction(let function) = value,
                   function.hasWorkerOperation {
                    return true
                }
            }

            if let member = syntax.as(MemberAccessExprSyntax.self),
               let baseExpression = member.base,
               let reference = baseExpression
                .as(DeclReferenceExprSyntax.self) {
                if let base = workerAdmissionValue(
                    named: reference.baseName.text,
                    in: closure.captured),
                   hostPropertyUsesWorkerOperation(
                    member.declName.baseName.text, on: base) {
                    return true
                }
            }

            for child in syntax.children(viewMode: .sourceAccurate) {
                if visit(child) { return true }
            }
            return false
        }

        for item in closure.body {
            if visit(Syntax(item)) { return true }
        }
        return false
    }

    private func memberDirectlyUsesWorkerHostOperation(
        _ member: MemberAccessExprSyntax,
        in env: Environment
    ) -> Bool {
        guard let baseExpression = member.base,
              let reference = baseExpression
                .as(DeclReferenceExprSyntax.self) else {
            return false
        }
        let name = reference.baseName.text
        guard let base = workerAdmissionValue(named: name, in: env) else {
            return false
        }
        return hostPropertyUsesWorkerOperation(
            member.declName.baseName.text, on: base)
    }

    /// Outermost roots that must be evaluated before an otherwise eager
    /// expression. Lazy/error-handling roots are kept whole so ternaries,
    /// short-circuit operators, and `try?` never execute an untaken branch.
    private func suspensionRoots(in expression: ExprSyntax) -> [ExprSyntax] {
        // A labeled closure argument reaches this helper as the expression
        // root itself. Starting the walk at its children would bypass the
        // closure guard below and eagerly execute awaits from the deferred
        // body while collecting call arguments.
        guard !expression.is(ClosureExprSyntax.self) else { return [] }
        var roots: [ExprSyntax] = []

        func walk(_ syntax: Syntax) {
            if syntax.is(ClosureExprSyntax.self) { return }
            if let node = syntax.as(AwaitExprSyntax.self) {
                roots.append(ExprSyntax(node))
                return
            }
            let lazyRoot: ExprSyntax?
            if let node = syntax.as(TryExprSyntax.self) {
                lazyRoot = ExprSyntax(node)
            } else if let node = syntax.as(TernaryExprSyntax.self) {
                lazyRoot = ExprSyntax(node)
            } else if let node = syntax.as(InfixOperatorExprSyntax.self) {
                lazyRoot = ExprSyntax(node)
            } else if let node = syntax.as(IfExprSyntax.self) {
                lazyRoot = ExprSyntax(node)
            } else if let node = syntax.as(SwitchExprSyntax.self) {
                lazyRoot = ExprSyntax(node)
            } else {
                lazyRoot = nil
            }
            if let lazyRoot, syntaxContainsSuspension(syntax) {
                roots.append(lazyRoot)
                return
            }
            for child in syntax.children(viewMode: .sourceAccurate) { walk(child) }
        }

        for child in Syntax(expression).children(viewMode: .sourceAccurate) {
            walk(child)
        }
        return roots
    }

    private func temporaryName() -> String {
        defer { asyncTemporarySerial += 1 }
        return "__dynamic_async_\(asyncTemporarySerial)"
    }

    private func evaluateLoweredSuspensions(
        _ expression: ExprSyntax, in env: Environment
    ) async throws -> RuntimeValue {
        let roots = suspensionRoots(in: expression)
        guard !roots.isEmpty else { return try evaluate(expression, in: env) }

        let child = Environment(parent: env)
        var replacements: [SyntaxIdentifier: String] = [:]
        for root in roots {
            try checkRuntimeCancellation()
            let name = temporaryName()
            let value = try await evaluateSuspending(root, in: env)
            child.define(name, value)
            replacements[root.id] = name
        }
        let rewriter = SuspensionReplacementRewriter(replacements: replacements)
        let rewritten = rewriter.visit(expression)
        return try evaluate(rewritten, in: child)
    }

    /// Async expression overlay. Await-free subtrees deliberately delegate to
    /// `evaluate`; only actual suspension paths fork, which keeps the sync
    /// SwiftUI renderer and the async script runner behaviorally aligned.
    func evaluateSuspending(
        _ expression: ExprSyntax,
        in env: Environment,
        forceInvocation: Bool = false
    ) async throws -> RuntimeValue {
        try checkRuntimeCancellation()

        switch expression.kind {
        case .awaitExpr:
            try tick(expression)
            let awaited = expression.cast(AwaitExprSyntax.self)
            return try await evaluateSuspending(
                awaited.expression, in: env, forceInvocation: true)

        case .tryExpr:
            try tick(expression)
            let attempt = expression.cast(TryExprSyntax.self)
            if attempt.questionOrExclamationMark?.text == "?" {
                do {
                    return try await evaluateSuspending(
                        attempt.expression, in: env,
                        forceInvocation: forceInvocation).liftedToOptional()
                } catch is InterpreterSessionAbort {
                    // Host/session teardown is evaluator control flow, not a
                    // source Error value. It must remain uncatchable by try?.
                    throw InterpreterSessionAbort()
                } catch let runtime as RuntimeError where runtime.fatal {
                    throw runtime
                } catch {
                    return .none()
                }
            }
            return try await evaluateSuspending(
                attempt.expression, in: env, forceInvocation: forceInvocation)

        case .ternaryExpr:
            try tick(expression)
            let ternary = expression.cast(TernaryExprSyntax.self)
            let condition = try expectBool(
                await evaluateSuspending(
                    ternary.condition,
                    in: env,
                    forceInvocation: forceInvocation),
                node: ternary.condition)
            return try await evaluateSuspending(
                condition ? ternary.thenExpression : ternary.elseExpression,
                in: env,
                forceInvocation: forceInvocation)

        case .infixOperatorExpr:
            return try await evaluateInfixSuspending(
                expression.cast(InfixOperatorExprSyntax.self), in: env,
                forceInvocation: forceInvocation)

        case .ifExpr:
            try tick(expression)
            let ifExpression = expression.cast(IfExprSyntax.self)
            if case .normal(let value) = try await executeIfSuspending(ifExpression, in: env) {
                return value
            }
            throw error(ifExpression, "control flow can't escape an if-expression")

        case .switchExpr:
            try tick(expression)
            let switchExpression = expression.cast(SwitchExprSyntax.self)
            if case .normal(let value) = try await executeSwitchSuspending(
                switchExpression, in: env) {
                return value
            }
            throw error(switchExpression, "control flow can't escape a switch-expression")

        case .functionCallExpr:
            let call = expression.cast(FunctionCallExprSyntax.self)
            let containsSourceSuspension = syntaxContainsSuspension(
                Syntax(expression))
            let usesWorkerHostOperation = forceInvocation
                || containsSourceSuspension
                ? false
                : callDirectlyUsesWorkerHostOperation(call, in: env)
            if forceInvocation || containsSourceSuspension
                || usesWorkerHostOperation {
                try tick(expression)
                return try await evaluateCallSuspending(
                    call,
                    in: env,
                    forceInvocation: forceInvocation)
            }
            return try evaluate(expression, in: env)

        case .memberAccessExpr:
            let member = expression.cast(MemberAccessExprSyntax.self)
            if forceInvocation {
                try tick(expression)
                if let baseExpression = member.base {
                    let base = try await evaluateSuspending(
                        baseExpression, in: env, forceInvocation: true)
                    if case .host(let payload) = base,
                       let handle = payload as? RuntimeTaskHandle {
                        switch GeneratedConcurrencySurface.taskInstanceIntrinsic(
                            memberName: member.declName.baseName.text
                        ) {
                        case .value:
                            return try await taskValue(from: handle)
                        case .result:
                            return await taskResult(from: handle)
                        case .cancel, .isCancelled, nil:
                            break
                        }
                    }
                    return try await accessMemberSuspending(
                        member.declName.baseName.text,
                        on: base,
                        node: member,
                        env: env)
                }
            } else if memberDirectlyUsesWorkerHostOperation(
                member, in: env), let baseExpression = member.base {
                try tick(expression)
                let base = try await evaluateSuspending(
                    baseExpression, in: env)
                return try await accessMemberSuspending(
                    member.declName.baseName.text,
                    on: base,
                    node: member,
                    env: env)
            }

        case .subscriptCallExpr:
            if forceInvocation {
                try tick(expression)
                let call = expression.cast(SubscriptCallExprSyntax.self)
                let base = try await evaluateSuspending(
                    call.calledExpression,
                    in: env,
                    forceInvocation: true)

                let receiver: (selfValue: RuntimeValue, liftsResult: Bool)?
                switch base.optionalState {
                case .some(let wrapped, _):
                    receiver = (wrapped, true)
                case .none:
                    receiver = nil
                case .notOptional:
                    receiver = (base, false)
                }

                if let receiver,
                   let (symbol, selfValue) = userSubscriptOwner(
                    for: receiver.selfValue) {
                    var arguments: [CallArguments.Argument] = []
                    for argument in call.arguments {
                        arguments.append(.init(
                            label: argument.label?.text,
                            value: try await evaluateSuspending(
                                argument.expression, in: env)))
                    }
                    let callArguments = CallArguments(arguments: arguments)
                    let member = try userSubscriptMember(
                        in: symbol, args: callArguments)
                    let executor: RuntimeExecutorKind?
                    if case .instance(let instance) = selfValue {
                        executor = try resolvedExecutor(
                            for: member, on: instance)
                    } else {
                        executor = nil
                    }
                    let result: RuntimeValue
                    if member.isAsync || executor != nil {
                        result = try await evaluateUserSubscriptGetterSuspending(
                            member,
                            symbolName: symbol.name,
                            selfValue: selfValue,
                            args: callArguments,
                            executor: executor)
                    } else {
                        result = try runUserSubscriptGetter(
                            member,
                            symbolName: symbol.name,
                            selfValue: selfValue,
                            args: callArguments)
                    }
                    return receiver.liftsResult
                        ? result.liftedToOptional() : result
                }

                // The base has already been evaluated exactly once. Rebind it
                // into the mature eager subscript evaluator; any suspension in
                // an index expression is lowered before that evaluator runs.
                let child = Environment(parent: env)
                let name = temporaryName()
                child.define(name, base)
                let replacement = ExprSyntax(
                    DeclReferenceExprSyntax(baseName: .identifier(name)))
                let rewritten = call.with(\.calledExpression, replacement)
                return try await evaluateLoweredSuspensions(
                    ExprSyntax(rewritten), in: child)
            }

        case .declReferenceExpr:
            if forceInvocation {
                let reference = expression.cast(DeclReferenceExprSyntax.self)
                if let binding = try asyncLetBinding(
                    named: reference.baseName.text, in: env) {
                    return try await binding.value(
                        waiter: evaluationTaskContext.runtimeTaskID)
                }
            }

        case .forceUnwrapExpr:
            if forceInvocation {
                try tick(expression)
                let unwrap = expression.cast(ForceUnwrapExprSyntax.self)
                let value = try await evaluateSuspending(
                    unwrap.expression, in: env, forceInvocation: true)
                guard let unwrapped = value.unwrappedOptionalOrSelf else {
                    throw error(unwrap, "unexpectedly found nil while force-unwrapping")
                }
                return unwrapped
            }

        case .optionalChainingExpr:
            if forceInvocation {
                try tick(expression)
                return try await evaluateSuspending(
                    expression.cast(OptionalChainingExprSyntax.self).expression,
                    in: env,
                    forceInvocation: true)
            }

        case .tupleExpr:
            if forceInvocation {
                let tuple = expression.cast(TupleExprSyntax.self)
                if tuple.elements.count == 1, let only = tuple.elements.first,
                   only.label == nil {
                    try tick(expression)
                    return try await evaluateSuspending(
                        only.expression, in: env, forceInvocation: true)
                }
            }

        default:
            break
        }

        return try await evaluateLoweredSuspensions(expression, in: env)
    }

    private func asyncLetBinding(
        named name: String, in env: Environment
    ) throws -> RuntimeAsyncLetBinding? {
        let box = env.box(for: name, before: globals)
            ?? (env === globals ? globals.box(for: name) : nil)
        guard let box else { return nil }
        return try force(box).hostPayload as? RuntimeAsyncLetBinding
    }

    private func taskValue(
        from handle: RuntimeTaskHandle
    ) async throws -> RuntimeValue {
        switch await handle.waitForOutcome(
            waiter: evaluationTaskContext.runtimeTaskID) {
        case .success(let value, _):
            return value
        case .failure(let errorValue, _):
            throw InterpretedThrow(value: errorValue)
        case .cancelled:
            throw CancellationError()
        }
    }

    private func taskResult(
        from handle: RuntimeTaskHandle
    ) async -> RuntimeValue {
        let outcome = await handle.waitForOutcome(
            waiter: evaluationTaskContext.runtimeTaskID)
        return .native(RuntimeResultValue(taskOutcome: outcome))
    }

    private func accessMemberSuspending(
        _ name: String,
        on base: RuntimeValue,
        node: some SyntaxProtocol,
        env: Environment
    ) async throws -> RuntimeValue {
        if case .instance(let instance) = base {
            let canonical = instance.symbol.canonicalPropertyName(name)
            if let computed = instance.symbol.computedProperties[canonical] {
                let executor = try resolvedExecutor(
                    for: computed, on: instance)
                if computed.isAsync || executor != nil {
                    return try await evaluateComputedSuspending(
                        computed,
                        selfValue: .instance(instance),
                        name: canonical,
                        executor: executor)
                }
            }
        }

        let eager = try accessMember(
            name,
            on: base,
            node: node,
            env: env,
            deferringAsyncHostProperty: true)
        return try await resolvePendingHostPropertyRead(eager, node: node).value
    }

    private func evaluateComputedSuspending(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String,
        executor: RuntimeExecutorKind?
    ) async throws -> RuntimeValue {
        let suspendedCallerActor = suspendCallerActorForExecutorHop(
            to: executor)
        do {
            let result = try await evaluateComputedOnExecutorSuspending(
                computed,
                selfValue: selfValue,
                name: name,
                executor: executor)
            if let suspendedCallerActor {
                await concurrencyRuntime.resumeActorExecutor(
                    suspendedCallerActor)
            }
            return result
        } catch {
            let failure = error
            if let suspendedCallerActor {
                await concurrencyRuntime.resumeActorExecutor(
                    suspendedCallerActor)
            }
            throw failure
        }
    }

    private func evaluateComputedOnExecutorSuspending(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String,
        executor: RuntimeExecutorKind?
    ) async throws -> RuntimeValue {
        let actorOwnership = try await enterActorInvocation(
            executor: executor)
        defer { leaveActorInvocation(actorOwnership) }
        if computed.isAsync {
            return try await evaluateComputedBodySuspending(
                computed, selfValue: selfValue, name: name)
        }
        return try evaluateComputed(
            computed, selfValue: selfValue, name: name)
    }

    private func evaluateUserSubscriptGetterSuspending(
        _ member: StructSymbol.SubscriptMember,
        symbolName: String,
        selfValue: RuntimeValue,
        args: CallArguments,
        executor: RuntimeExecutorKind?
    ) async throws -> RuntimeValue {
        let suspendedCallerActor = suspendCallerActorForExecutorHop(
            to: executor)
        do {
            let result = try await evaluateUserSubscriptGetterOnExecutorSuspending(
                member,
                symbolName: symbolName,
                selfValue: selfValue,
                args: args,
                executor: executor)
            if let suspendedCallerActor {
                await concurrencyRuntime.resumeActorExecutor(
                    suspendedCallerActor)
            }
            return result
        } catch {
            let failure = error
            if let suspendedCallerActor {
                await concurrencyRuntime.resumeActorExecutor(
                    suspendedCallerActor)
            }
            throw failure
        }
    }

    private func evaluateUserSubscriptGetterOnExecutorSuspending(
        _ member: StructSymbol.SubscriptMember,
        symbolName: String,
        selfValue: RuntimeValue,
        args: CallArguments,
        executor: RuntimeExecutorKind?
    ) async throws -> RuntimeValue {
        let actorOwnership = try await enterActorInvocation(executor: executor)
        defer { leaveActorInvocation(actorOwnership) }
        if member.isAsync {
            return try await runUserSubscriptGetterSuspending(
                member,
                symbolName: symbolName,
                selfValue: selfValue,
                args: args)
        }
        return try runUserSubscriptGetter(
            member,
            symbolName: symbolName,
            selfValue: selfValue,
            args: args)
    }

    private func resolvePendingHostPropertyRead(
        _ value: RuntimeValue,
        node: some SyntaxProtocol
    ) async throws -> (value: RuntimeValue, didResolve: Bool) {
        switch value {
        case .host(let payload):
            guard let pending = payload as? PendingHostPropertyRead else {
                return (value, false)
            }
            let context = TaskBoundEvalContext(
                interpreter: self,
                evaluationContext: evaluationTaskContext)
            do {
                return (
                    try await pending.property.readSuspending(
                        from: pending.receiver, in: context),
                    true)
            } catch let runtime as RuntimeError where runtime.line == 0 {
                throw error(node, locating: runtime)
            }

        case .optional(let optional):
            guard let wrapped = optional.wrapped else {
                return (value, false)
            }
            let resolved = try await resolvePendingHostPropertyRead(
                wrapped, node: node)
            guard resolved.didResolve else { return (value, false) }
            return (
                resolved.value.liftedToOptional(
                    wrappedTypeName: optional.wrappedTypeName),
                true)

        default:
            return (value, false)
        }
    }

    func withExpectedAnnotationSuspending<T>(
        _ annotation: String?,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard let annotation, !annotation.isEmpty else { return try await body() }
        expectedAnnotationStack.append(annotation)
        defer { expectedAnnotationStack.removeLast() }
        return try await body()
    }

    private func evaluateInfixSuspending(
        _ infix: InfixOperatorExprSyntax, in env: Environment,
        forceInvocation: Bool
    ) async throws -> RuntimeValue {
        try checkRuntimeCancellation()
        try tick(infix)

        let binary = infix.operator.as(BinaryOperatorExprSyntax.self)
        let op = binary?.operator.text
        if infix.operator.is(AssignmentExprSyntax.self)
            || ["+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]
                .contains(op) {
            let hint = assignmentAnnotationHint(infix.leftOperand, in: env)
            let rhs = try await withExpectedAnnotationSuspending(hint) {
                try await evaluateSuspending(
                    infix.rightOperand, in: env,
                    forceInvocation: forceInvocation)
            }
            let child = Environment(parent: env)
            let name = temporaryName()
            child.define(name, rhs)
            let replacement = ExprSyntax(
                DeclReferenceExprSyntax(baseName: .identifier(name)))
            let rewritten = infix.with(\.rightOperand, replacement)
            // The outer node was already charged; the established write path
            // may charge it once more, matching sync's nested expression cost.
            return try evaluateInfix(rewritten, in: child)
        }

        switch op {
        case "&&":
            guard try expectBool(
                await evaluateSuspending(
                    infix.leftOperand, in: env,
                    forceInvocation: forceInvocation),
                node: infix.leftOperand) else { return .native(false) }
            return .native(try expectBool(
                await evaluateSuspending(
                    infix.rightOperand, in: env,
                    forceInvocation: forceInvocation),
                node: infix.rightOperand))
        case "||":
            if try expectBool(
                await evaluateSuspending(
                    infix.leftOperand, in: env,
                    forceInvocation: forceInvocation),
                node: infix.leftOperand) { return .native(true) }
            return .native(try expectBool(
                await evaluateSuspending(
                    infix.rightOperand, in: env,
                    forceInvocation: forceInvocation),
                node: infix.rightOperand))
        case "??":
            let lhs = try await evaluateSuspending(
                infix.leftOperand, in: env,
                forceInvocation: forceInvocation)
            switch lhs.optionalState {
            case .none:
                return try await evaluateSuspending(
                    infix.rightOperand, in: env,
                    forceInvocation: forceInvocation)
            case .some(let wrapped, _):
                return wrapped
            case .notOptional:
                return lhs
            }
        default:
            var lhs = try await evaluateSuspending(
                infix.leftOperand, in: env,
                forceInvocation: forceInvocation)
            var rhs = try await evaluateSuspending(
                infix.rightOperand, in: env,
                forceInvocation: forceInvocation)
            // Lowering replaces both operands with temporary identifiers, so
            // retain the original syntax's contextual-literal information.
            (lhs, rhs) = try contextualizeSetLiteralEquality(
                lhs, rhs, op: op ?? "",
                leftIsLiteral: infix.leftOperand.is(ArrayExprSyntax.self),
                rightIsLiteral: infix.rightOperand.is(ArrayExprSyntax.self))
            let child = Environment(parent: env)
            let lhsName = temporaryName()
            let rhsName = temporaryName()
            child.define(lhsName, lhs)
            child.define(rhsName, rhs)
            let rewritten = infix
                .with(\.leftOperand, ExprSyntax(
                    DeclReferenceExprSyntax(baseName: .identifier(lhsName))))
                .with(\.rightOperand, ExprSyntax(
                    DeclReferenceExprSyntax(baseName: .identifier(rhsName))))
            return try evaluateInfix(rewritten, in: child)
        }
    }

    // MARK: - Calls and invocation

    func collectArgumentsSuspending(
        of call: FunctionCallExprSyntax, in env: Environment
    ) async throws -> CallArguments {
        var arguments: [CallArguments.Argument] = []
        for argument in callSiteMetadata(for: call).arguments {
            let value: RuntimeValue
            if let trailingClosure = argument.trailingClosure {
                value = .closure(try makeClosure(trailingClosure, in: env))
            } else {
                value = try await evaluateSuspending(argument.expression, in: env)
            }
            arguments.append(.init(
                label: argument.label,
                value: value,
                isTrailing: argument.isTrailing,
                sourceProvenance: callArgumentSourceProvenance(
                    of: argument, value: value, in: env)))
        }
        return CallArguments(arguments: arguments)
    }

    /// Suspension-aware call-site resolution. Ordinary calls still use the
    /// mature synchronous evaluator; this path is entered only beneath await
    /// (or when an argument itself suspends).
    /// A supplied write-back transaction ends an enclosing storage borrow on
    /// both normal and exceptional method completion, before an error escapes.
    func invokeMutatingInstanceMethodSuspending(
        named name: String,
        on current: RuntimeValue,
        arguments: CallArguments,
        node: some SyntaxProtocol,
        writeBackOnExit: ((RuntimeValue) throws -> Void)? = nil
    ) async throws -> (result: RuntimeValue, receiver: RuntimeValue)? {
        guard case .instance(let receiver) = current,
              !receiver.symbol.isClass else { return nil }
        let mutating = mutatingInstanceMethods(named: name, on: receiver)
        guard !mutating.isEmpty,
              let method = chooseFunction(from: mutating, for: arguments)
                ?? mutating.first,
              let body = functionMetadata(for: method).body,
              case .instance(let working) = current.copiedForValueSemantics()
        else { return nil }

        let selfEnvironment = selfEnvironment(.instance(working))
        let closure = makeFunctionClosure(
            method, body: body, captured: selfEnvironment)
        func finalReceiver() throws -> RuntimeValue {
            let finalSelf = selfEnvironment.lookup("self") ?? .instance(working)
            return try resolveAnnotated(
                finalSelf, typeName: receiver.symbol.name)
        }

        let result: RuntimeValue
        do {
            result = try await callWithArgumentsSuspending(
                closure, args: arguments, node: Syntax(node))
        } catch {
            let failure = error
            try writeBackOnExit?(finalReceiver())
            throw failure
        }
        let resolvedReceiver = try finalReceiver()
        try writeBackOnExit?(resolvedReceiver)
        return (result, resolvedReceiver)
    }

    /// Optional async write-back admits a local binding or one directly named
    /// source property. A synchronous nonthrowing computed get/set pair can
    /// use the same suspension-spanning copy-in/copy-out transaction as stored
    /// value storage; native coroutine and subscript accessors remain separate.
    private func isSupportedOptionalAsyncMutationStorageSyntax(
        _ expression: ExprSyntax
    ) -> Bool {
        if expression.is(DeclReferenceExprSyntax.self) {
            return true
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              let base = member.base else {
            return false
        }
        return base.is(DeclReferenceExprSyntax.self)
    }

    /// A suspension-aware mutating-method probe is meaningful only for an
    /// assignable-looking postfix chain. Function-call roots are rvalues and
    /// deliberately excluded: probing `Task.detached { ... }.result` as an
    /// lvalue would launch the task a second time before invoking
    /// `Result.get()`.
    private func isSuspendingMutationStorageSyntax(
        _ expression: ExprSyntax
    ) -> Bool {
        if expression.is(DeclReferenceExprSyntax.self) { return true }
        if let member = expression.as(MemberAccessExprSyntax.self),
           let base = member.base {
            return isSuspendingMutationStorageSyntax(base)
        }
        if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
            return isSuspendingMutationStorageSyntax(
                subscriptCall.calledExpression)
        }
        if let optional = expression.as(OptionalChainingExprSyntax.self) {
            return isSuspendingMutationStorageSyntax(optional.expression)
        }
        if let force = expression.as(ForceUnwrapExprSyntax.self) {
            return isSuspendingMutationStorageSyntax(force.expression)
        }
        if let tuple = expression.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first {
            return isSuspendingMutationStorageSyntax(only.expression)
        }
        return false
    }

    private func isSupportedOptionalAsyncMutationLValue(
        _ target: LValue
    ) -> Bool {
        switch target {
        case .box:
            return true
        case .instanceProperty(let instance, let name):
            return instance.symbol.storedProperty(named: name) != nil
        case .instanceValueProperty(let base, let symbol, let name):
            if symbol.storedProperty(named: name) != nil {
                return isSupportedOptionalAsyncMutationLValue(base)
            }
            guard let computed = symbol.computedProperties[name],
                  computed.setter != nil,
                  !computed.isAsync,
                  !computed.isThrowing,
                  let typeName = computed.typeName,
                  RuntimeOptionalValue.wrappedType(in: typeName) != nil else {
                return false
            }
            return isSupportedOptionalAsyncMutationLValue(base)
        default:
            return false
        }
    }

    private func replacingOptionalPayload(
        in optionalValue: RuntimeValue,
        with payload: RuntimeValue
    ) -> RuntimeValue {
        guard case .optional(let optional) = optionalValue else {
            return payload.liftedToOptional()
        }
        return .some(
            payload,
            wrappedTypeName: optional.wrappedTypeName,
            isImplicitlyUnwrapped: optional.isImplicitlyUnwrapped)
    }

    func evaluateCallSuspending(
        _ call: FunctionCallExprSyntax,
        in env: Environment,
        forceInvocation: Bool
    ) async throws -> RuntimeValue {
        let calleeMetadata = callSiteMetadata(for: call).callee
        if calleeMetadata.shape == .explicitMember,
           let member = calleeMetadata.member,
           let baseExpression = member.base {
            let name = member.declName.baseName.text
            // A writable optional value must be borrowed through its storage
            // for the whole async mutating call. Resolve the admitted stored
            // path before reading it, then commit through that same lvalue.
            let optionalPayloadStorage: LValue?
            let mutationStorage: LValue?
            let evaluatedBase: RuntimeValue
            if let optional = baseExpression
                .as(OptionalChainingExprSyntax.self),
               isSupportedOptionalAsyncMutationStorageSyntax(
                   optional.expression),
               let storage = try? resolveLValue(optional.expression, in: env),
               isSupportedOptionalAsyncMutationLValue(storage) {
                optionalPayloadStorage = storage
                mutationStorage = nil
                evaluatedBase = try storage.read(self)
            } else {
                optionalPayloadStorage = nil
                evaluatedBase = try await evaluateSuspending(
                    baseExpression,
                    in: env,
                    forceInvocation: forceInvocation)
                mutationStorage = isSuspendingMutationStorageSyntax(
                    baseExpression)
                    ? (try? resolveLValue(baseExpression, in: env))
                    : nil
            }

            // Optional chaining controls the entire call: evaluate the base
            // once, skip arguments and invocation for nil, or dispatch the
            // wrapped source reference through this same suspension-aware
            // call path before flattening the result back to one Optional
            // level. The admitted source-value storage subset instead uses
            // the lvalue transaction above so rebinding cannot lose write-back.
            if baseExpression.is(OptionalChainingExprSyntax.self) {
                switch evaluatedBase.optionalState {
                case .none:
                    return .none()
                case .some(let wrapped, _):
                    if case .instance(let instance) = wrapped,
                       instance.symbol.isClass || instance.symbol.isActor {
                        let child = Environment(parent: env)
                        let temporary = temporaryName()
                        child.define(temporary, wrapped)
                        let replacement = ExprSyntax(
                            DeclReferenceExprSyntax(
                                baseName: .identifier(temporary)))
                        let rewrittenMember = member.with(
                            \.base, replacement)
                        let rewrittenCall = call.with(
                            \.calledExpression,
                            ExprSyntax(rewrittenMember))
                        return try await evaluateCallSuspending(
                            rewrittenCall,
                            in: child,
                            forceInvocation: forceInvocation
                        ).liftedToOptional()
                    }
                    if case .instance(let instance) = wrapped,
                       !instance.symbol.isClass,
                       !mutatingInstanceMethods(
                            named: name, on: instance).isEmpty {
                        guard let storage = optionalPayloadStorage else {
                            throw error(
                                call,
                                "async optional value mutation through a "
                                    + "computed reference owner or unsupported "
                                    + "storage path is unsupported; use direct "
                                    + "stored Optional storage or a synchronous "
                                    + "nonthrowing computed property on a "
                                    + "source value")
                        }
                        let args = try await collectArgumentsSuspending(
                            of: call, in: env)
                        if let invocation = try await
                            invokeMutatingInstanceMethodSuspending(
                                named: name,
                                on: wrapped,
                                arguments: args,
                                node: call,
                                writeBackOnExit: { receiver in
                                    try self.relocating(call) {
                                        try storage.writeOwned(
                                            self.replacingOptionalPayload(
                                                in: evaluatedBase,
                                                with: receiver),
                                            self)
                                    }
                                }) {
                            return invocation.result.liftedToOptional()
                        }
                    }
                case .notOptional:
                    break
                }
            }
            let baseValue = evaluatedBase

            // Host-type source extensions, plus any imported peer, compete
            // only once argument types are available. Use the same target
            // resolver as eager evaluation, then retain suspension-aware
            // invocation.
            if let overloads = try hostExtensionMethodOverloads(
                named: name,
                on: baseValue,
                declaredTypeName: declaredMemberReceiverTypeName(
                    for: baseExpression, in: env)
            ) {
                let args = try await collectArgumentsSuspending(
                    of: call, in: env)
                let target = try resolveHostExtensionMethodTarget(
                    overloads, arguments: args)
                return try await invokeSuspending(
                    target,
                    with: args,
                    node: call,
                    sourceAllowsHostSuspension: forceInvocation)
            }

            // Provenance uses `_Concurrency.MainActor.run(body:)` after a
            // detached sleep. Admit that API only through the intrinsic
            // generated from the active _Concurrency.swiftinterface. A bare
            // host-type marker is the imported nominal identity; same-named
            // source types resolve to source symbols before reaching this
            // branch. Execute the synchronous trailing body under the logical
            // MainActor executor and return its value instead of degrading the
            // static member to an inert implicit-member marker.
            if case .host(let payload) = baseValue,
               let marker = payload as? HostTypeMarker,
               GeneratedConcurrencySurface.nominalMemberIntrinsic(
                typeName: marker.name, memberName: name) == .mainActorRun {
                guard call.arguments.isEmpty,
                      call.trailingClosure != nil,
                      call.additionalTrailingClosures.isEmpty else {
                    throw error(
                        call,
                        "MainActor.run(resultType:body:) is unsupported; "
                            + "only the demand-backed MainActor.run(body:) "
                            + "spelling is supported")
                }
                let arguments = try await collectArgumentsSuspending(
                    of: call, in: env)
                guard arguments.arguments.count == 1,
                      let body = arguments.lastUnlabeledClosure else {
                    throw error(
                        call,
                        "MainActor.run(body:) requires one trailing closure")
                }
                return try await callWithArgumentsSuspending(
                    body,
                    args: CallArguments(),
                    node: Syntax(call),
                    contextualExecutor: .mainActor)
            }

            if let target = mutationStorage,
               case .instance(let receiver) = baseValue,
               !receiver.symbol.isClass {
                let mutating = mutatingInstanceMethods(named: name, on: receiver)
                if !mutating.isEmpty {
                    let args = try await collectArgumentsSuspending(of: call, in: env)
                    if let invocation = try await
                        invokeMutatingInstanceMethodSuspending(
                            named: name,
                            on: baseValue,
                            arguments: args,
                            node: call) {
                        try relocating(call) {
                            try target.writeOwned(invocation.receiver, self)
                        }
                        return invocation.result
                    }
                }
            }

            // FoodTruck's detached updates loop is the first demand-cited
            // source-call target. Resolve an argument-free own reference
            // method to one exact origin declaration before invocation; the
            // descriptor is Sendable, while this closure and receiver stay
            // on the MainActor-confined evaluator.
            if call.arguments.isEmpty,
               call.trailingClosure == nil,
               call.additionalTrailingClosures.isEmpty,
               case .instance(let instance) = baseValue,
               let target = resolveOwnSourceInstanceMethodCallTarget(
                   named: name,
                   on: instance,
                   arguments: CallArguments()) {
                return try await invokeSuspending(
                    .closure(target.closure),
                    with: CallArguments(),
                    node: call)
            }

            if case .instance(let instance) = baseValue,
               let overloads = instanceMethodOverloads(
                   named: name, on: instance),
               shouldDirectlyDispatchInstanceCall(
                   named: name, on: instance, overloads: overloads) {
                let args = try await collectArgumentsSuspending(of: call, in: env)
                let fitting = functionsFittingCall(
                    from: overloads, args: args)
                if !fitting.isEmpty {
                    let available = functionsAvailableForCall(
                        from: fitting, args: args)
                    if available.isEmpty {
                        return .native(ChainedImplicitCall(
                            base: baseValue, member: name, arguments: args))
                    }
                    if let method = chooseFunction(
                        from: available, for: args) ?? available.first,
                       let body = functionMetadata(for: method).body {
                        let closure = makeFunctionClosure(
                            method, body: body,
                            captured: instanceMethodEnvironment(instance))
                        return try await invokeSuspending(
                            .closure(closure), with: args, node: call)
                    }
                }
            }
            if case .type(let symbol) = baseValue,
               let overloads = staticMethodOverloads(
                   named: name, on: symbol), overloads.count > 1 {
                let args = try await collectArgumentsSuspending(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = functionMetadata(for: method).body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.type(symbol)))
                    return try await invokeSuspending(
                        .closure(closure), with: args, node: call)
                }
            }
            if case .enumType(let symbol) = baseValue,
               let overloads = symbol.staticMethods[name], !overloads.isEmpty,
               !call.arguments.isEmpty || call.trailingClosure != nil
                   || symbol.staticComputedProperties[name] == nil {
                let args = try await collectArgumentsSuspending(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if let method = chooseFunction(from: available, for: args) ?? available.first,
                   let body = functionMetadata(for: method).body {
                    let closure = makeFunctionClosure(
                        method, body: body,
                        captured: selfEnvironment(.enumType(symbol)))
                    return try await invokeSuspending(
                        .closure(closure), with: args, node: call)
                }
            }

            let callee: RuntimeValue
            if forceInvocation {
                callee = try await accessMemberSuspending(
                    name, on: baseValue, node: member, env: env)
            } else {
                callee = try accessMember(
                    name, on: baseValue, node: member, env: env)
            }
            let args = try await collectArgumentsSuspending(of: call, in: env)
            do {
                return try await invokeSuspending(
                    callee,
                    with: args,
                    node: call,
                    sourceAllowsHostSuspension: forceInvocation)
            } catch let bindingError as RuntimeError
                where !bindingError.fatal
                    && (bindingError.message.hasPrefix("missing argument")
                        || bindingError.message.hasSuffix("is not callable")) {
                if case .instance(let instance) = baseValue {
                    let family = functionsAvailableForCall(
                        from: instanceMethodOverloads(
                            named: name, on: instance) ?? [],
                        args: args)
                    if let method = chooseFunction(from: family, for: args),
                       let body = functionMetadata(for: method).body {
                        let closure = makeFunctionClosure(
                            method, body: body,
                            captured: instanceMethodEnvironment(instance))
                        return try await invokeSuspending(
                            .closure(closure), with: args, node: call)
                    }
                    for conformance in transitiveConformances(
                        of: instance.symbol
                    ) {
                        guard let protocolSymbol =
                                hostExtensionSymbols[conformance],
                              let overloads = protocolSymbol.methods[name]
                        else { continue }
                        let available = functionsAvailableForCall(
                            from: overloads, args: args)
                        guard let method = chooseFunction(
                            from: available, for: args),
                              let body = functionMetadata(for: method).body
                        else { continue }
                        let closure = makeFunctionClosure(
                            method, body: body,
                            captured: instanceMethodEnvironment(instance))
                        return try await invokeSuspending(
                            .closure(closure), with: args, node: call)
                    }
                }
                if let any = baseValue.hostPayload,
                   let method = registry?.hostMethod(name, on: any) {
                    return try await invokeSuspending(
                        method,
                        with: args,
                        node: call,
                        sourceAllowsHostSuspension: forceInvocation)
                }
                throw bindingError
            }
        }

        if calleeMetadata.shape == .directReference,
           let name = calleeMetadata.name,
           env.box(for: name, before: globals) == nil {
            if let overloads = globalFunctionOverloads[name], overloads.count > 1 {
                let args = try await collectArgumentsSuspending(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if let function = chooseFunction(from: available, for: args) ?? available.first,
                   let body = functionMetadata(for: function).body {
                    let closure = makeFunctionClosure(function, body: body, captured: globals)
                    return try await invokeSuspending(
                        .closure(closure), with: args, node: call)
                }
            }
            if case .instance(let instance)? = env.lookup("self"),
               let overloads = instanceMethodOverloads(
                   named: name, on: instance),
               shouldDirectlyDispatchImplicitSelfCall(
                   named: name, on: instance, overloads: overloads) {
                let args = try await collectArgumentsSuspending(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if let function = chooseFunction(from: available, for: args) ?? available.first,
                   let body = functionMetadata(for: function).body {
                    let methodEnvironment = methodIsMutating(function)
                        ? selfEnvironment(.instance(instance))
                        : instanceMethodEnvironment(instance)
                    let closure = makeFunctionClosure(
                        function, body: body,
                        captured: methodEnvironment)
                    return try await invokeSuspending(
                        .closure(closure), with: args, node: call)
                }
            }
        }

        let callee = try await evaluateSuspending(
            calleeMetadata.expression, in: env)

        // An optional callable controls the whole invocation. Preserve the
        // suspension-aware path for a present closure, but do not evaluate
        // arguments at all when optional chaining finds nil.
        if call.calledExpression.is(OptionalChainingExprSyntax.self) {
            switch callee.optionalState {
            case .none:
                return .none()
            case .some(let wrapped, _):
                let args = try await collectArgumentsSuspending(
                    of: call, in: env)
                return try await invokeSuspending(
                    wrapped,
                    with: args,
                    node: call,
                    sourceAllowsHostSuspension: forceInvocation
                ).liftedToOptional()
            case .notOptional:
                break
            }
        }

        let args = try await collectArgumentsSuspending(of: call, in: env)
        return try await invokeSuspending(
            callee,
            with: args,
            node: call,
            sourceAllowsHostSuspension: forceInvocation)
    }

    func invokeSuspending(
        _ callee: RuntimeValue,
        with originalArguments: CallArguments,
        node: some SyntaxProtocol,
        sourceAllowsHostSuspension: Bool = true
    ) async throws -> RuntimeValue {
        var arguments = originalArguments
        switch callee {
        case .closure, .type:
            break
        default:
            arguments = arguments.unwrappingInoutSlots()
        }

        switch callee {
        case .closure(let closure):
            return try await callWithArgumentsSuspending(
                closure, args: arguments, node: Syntax(node))

        case .type(let symbol):
            return try await instantiateSuspending(
                symbol, with: arguments, node: Syntax(node))

        case .instance(let instance)
            where instance.symbol.methods["callAsFunction"] != nil:
            if let overloads = instance.symbol.methods["callAsFunction"],
               let method = chooseFunction(from: overloads, for: arguments) ?? overloads.first,
               let body = functionMetadata(for: method).body {
                let closure = makeFunctionClosure(
                    method, body: body,
                    captured: instanceMethodEnvironment(instance))
                return try await callWithArgumentsSuspending(
                    closure, args: arguments, node: Syntax(node))
            }
            return .void

        case .hostFunction(let function):
            if let extensionSymbol = hostExtensionSymbols[function.name] {
                let available = extensionSymbol.initializers.filter {
                    !activeInitializers.contains($0.id)
                        && !isCodableInitializer($0)
                }
                if let chosen = available.first(where: {
                    extensionInitFits($0, args: arguments)
                }), let body = initializerMetadata(for: chosen).body {
                    let inserted = activeInitializers.insert(chosen.id).inserted
                    defer { if inserted { activeInitializers.remove(chosen.id) } }
                    let env = Environment(parent: globals)
                    env.define("self", .void)
                    let closure = makeInitializerClosure(
                        chosen,
                        body: body,
                        captured: env,
                        debugName: "extInit:\(function.name)",
                        fallbackLexicalOwner: extensionSymbol)
                    _ = try await callWithArgumentsSuspending(
                        closure, args: arguments, node: Syntax(node))
                    let assigned = env.lookup("self") ?? .void
                    if case .void = assigned {
                        // Fall through to the registered host gateway.
                    } else {
                        return assigned
                    }
                }
            }
            if let generated = try RuntimeUnicodeDecodingConstructor.invoke(
                named: function.name,
                arguments: arguments
            ) {
                return generated
            }
            do {
                if function.canSuspend
                    && (sourceAllowsHostSuspension
                        || function.hasWorkerOperation) {
                    let context = TaskBoundEvalContext(
                        interpreter: self,
                        evaluationContext: evaluationTaskContext)
                    return try await function.invokeSuspending(arguments, context)
                }
                return try function.invoke(arguments, self)
            } catch let runtime as RuntimeError where runtime.line == 0 {
                throw error(node, locating: runtime)
            }

        default:
            // Constructors, enum calls, markers, keypaths, and inert values
            // have no suspension point of their own and retain the complete
            // synchronous dispatch implementation.
            return try invoke(callee, with: arguments, node: node)
        }
    }

    func callWithArgumentsSuspending(
        _ closure: ClosureValue,
        args: CallArguments,
        node: Syntax?,
        contextualExecutor: RuntimeExecutorKind? = nil,
        inheritsAnonymousClosureLexicalExecutor: Bool = true
    ) async throws -> RuntimeValue {
        let programState = closure.programState
        evaluationTaskContext.enterProgramState(programState)
        defer {
            evaluationTaskContext.leaveProgramState(programState)
        }
        lexicalSourceModuleFrames.append(closure.sourceModuleName)
        defer { lexicalSourceModuleFrames.removeLast() }
        let invocation = try resolvedInvocation(
            for: closure, arguments: args)
        let effectiveArguments = invocation.arguments
        let calleeExecutor = contextualExecutor ?? invocation.executor
        let suspendedCallerActor = suspendCallerActorForExecutorHop(
            to: calleeExecutor)
        do {
            let result = try await callWithArgumentsOnExecutorSuspending(
                closure,
                args: effectiveArguments,
                node: node,
                calleeExecutor: calleeExecutor,
                contextualExecutor: contextualExecutor,
                inheritsAnonymousClosureLexicalExecutor:
                    inheritsAnonymousClosureLexicalExecutor)
            if let suspendedCallerActor {
                await concurrencyRuntime.resumeActorExecutor(
                    suspendedCallerActor)
            }
            return result
        } catch {
            let failure = error
            if let suspendedCallerActor {
                await concurrencyRuntime.resumeActorExecutor(
                    suspendedCallerActor)
            }
            throw failure
        }
    }

    private func callWithArgumentsOnExecutorSuspending(
        _ closure: ClosureValue,
        args: CallArguments,
        node: Syntax?,
        calleeExecutor: RuntimeExecutorKind?,
        contextualExecutor: RuntimeExecutorKind?,
        inheritsAnonymousClosureLexicalExecutor: Bool
    ) async throws -> RuntimeValue {
        let actorOwnership = try await enterActorInvocation(
            executor: calleeExecutor)
        defer { leaveActorInvocation(actorOwnership) }
        callDepth += 1
        defer { callDepth -= 1 }
        let previousExecutor = evaluationTaskContext.currentExecutor
        if let executor = calleeExecutor {
            evaluationTaskContext.currentExecutor = executor
        }
        defer { evaluationTaskContext.currentExecutor = previousExecutor }
        lexicalExecutorFrames.append(
            closure.functionDeclID == nil
                ? (inheritsAnonymousClosureLexicalExecutor
                    ? contextualExecutor ?? closure.lexicalExecutor
                    : calleeExecutor)
                : calleeExecutor)
        defer { lexicalExecutorFrames.removeLast() }
        var insertedFrame: ExtensionFrame?
        if let frame = closure.extensionFrame,
           activeExtensionFrames.insert(frame).inserted {
            insertedFrame = frame
        }
        defer { if let insertedFrame { activeExtensionFrames.remove(insertedFrame) } }
        var insertedBody: SyntaxIdentifier?
        if let declaration = closure.functionDeclID,
           activeFunctionBodies.insert(declaration).inserted {
            insertedBody = declaration
        }
        defer { if let insertedBody { activeFunctionBodies.remove(insertedBody) } }
        var pushedLexicalOwner = false
        if let owner = closure.lexicalOwner {
            lexicalOwnerFrames.append(owner)
            pushedLexicalOwner = true
        }
        defer { if pushedLexicalOwner { lexicalOwnerFrames.removeLast() } }

        guard callDepth < callDepthLimit else {
            if let node {
                let located = error(node, "call depth exceeded (possible infinite recursion)")
                throw RuntimeError(
                    message: located.message, line: located.line,
                    column: located.column, fatal: true)
            }
            throw RuntimeError(
                message: "call depth exceeded (possible infinite recursion)", fatal: true)
        }

        let env = Environment(parent: closure.captured)
        let writeBacks = try bindParameters(of: closure, to: args, into: env, node: node)
        if let functionName = closure.sourceFunctionName {
            env.define("#function", .native(functionName))
        }
        if !closure.genericParameters.isEmpty {
            bindGenericReturnParameter(closure, into: env)
            bindGenericsFromClosureArguments(closure, args: args, into: env)
        }
        func applyInoutWriteBacks() throws {
            for entry in writeBacks {
                if let target = entry.slot.target, let box = env.box(for: entry.name) {
                    try target.writeOwned(box.value, self)
                }
            }
        }

        if closure.isBuilder {
            // Result builders are consumed by the synchronous renderer and
            // cannot suspend while producing `body`.
            let items = try collectBuilderViews(closure.body, in: env)
            try applyInoutWriteBacks()
            if closure.builderReturnsArray { return .native(items) }
            return try groupViews(items)
        }

        enclosingReturnAnnotations.append(closure.returnTypeName)
        defer { enclosingReturnAnnotations.removeLast() }
        if Interpreter.traceStateCells {
            let label = closure.debugName ?? "closure{" + closure.body.description
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ").prefix(48) + "}"
            callStackNames.append(String(label))
        }
        defer {
            if Interpreter.traceStateCells, !callStackNames.isEmpty {
                callStackNames.removeLast()
            }
        }

        let singleExpressionBody: Bool = {
            guard closure.body.count == 1,
                  let item = closure.body.first?.item else { return false }
            if case .expr = item { return true }
            return false
        }()
        let hintIsOwnGeneric: Bool = {
            guard let hint = closure.returnTypeName else { return true }
            return closure.genericParameters.contains { parameter in
                hint.split(whereSeparator: {
                    !($0.isLetter || $0.isNumber || $0 == "_")
                }).contains(Substring(parameter))
            }
        }()

        let result: StatementResult
        if singleExpressionBody, !hintIsOwnGeneric,
           let returnHint = closure.returnTypeName {
            result = try await withExpectedAnnotationSuspending(returnHint) {
                try await executeBlockSuspending(closure.body, in: env)
            }
        } else {
            result = try await executeBlockSuspending(closure.body, in: env)
        }
        try applyInoutWriteBacks()
        switch result {
        case .normal(let value), .returnValue(let value):
            if let returnTypeName = closure.returnTypeName {
                return try resolveAnnotated(value, typeName: returnTypeName)
            }
            return value
        case .breakLoop, .continueLoop:
            throw RuntimeError(message: "break/continue escaped a function body")
        }
    }
}
