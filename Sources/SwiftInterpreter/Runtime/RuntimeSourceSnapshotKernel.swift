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
        }
    }
}

/// Executor-neutral work lowered from an explicitly admitted source closure.
/// The demand-scoped surface is a literal or a typed snapshot expression. The
/// kernel owns no syntax, evaluator, environment, closure, heap, or host value.
nonisolated enum RuntimeSourceSnapshotKernel: Sendable, Equatable {
    case constant(RuntimeWorkerValueSnapshot)
    case expression(RuntimeSourceSnapshotExpression)

    func execute(
        with capability: RuntimeWorkerCapability
    ) throws -> RuntimeWorkerValueSnapshot {
        guard capability.accessManifest.isWorkerSafe else {
            throw RuntimeError(message:
                "physical source kernel received an unsafe worker manifest")
        }
        try Task.checkCancellation()
        switch self {
        case .constant(let value):
            return value
        case .expression(let expression):
            return try expression.execute(with: capability)
        }
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
        priority: RuntimeTaskPriority
    ) throws -> RuntimePhysicalWorkerJob? {
        guard physicalWorkerDriver != nil,
              arguments.isEmpty,
              closure.parameters.isEmpty,
              !closure.isBuilder,
              closure.isPhysicalSnapshotKernelCandidate,
              closure.body.count == 1,
              let item = closure.body.first,
              let expression = Self.singleExpression(in: item) else {
            return nil
        }

        let capability: RuntimeWorkerCapability
        let kernel: RuntimeSourceSnapshotKernel
        if let value = literalWorkerSnapshot(expression) {
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
        } else {
            return nil
        }
        return RuntimePhysicalWorkerJob(
            capability: capability,
            priority: priority
        ) { capability in
            try kernel.execute(with: capability)
        }
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
              reference.argumentNames == nil else {
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
              reference.argumentNames == nil else {
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
