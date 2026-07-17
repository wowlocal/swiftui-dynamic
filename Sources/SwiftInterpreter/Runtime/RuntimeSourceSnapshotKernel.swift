import SwiftSyntax

/// Executor-neutral work lowered from an explicitly admitted source closure.
/// The initial demand-scoped surface is one literal expression only. The
/// kernel owns no syntax, evaluator, environment, closure, heap, or host value.
nonisolated enum RuntimeSourceSnapshotKernel: Sendable, Equatable {
    case constant(RuntimeWorkerValueSnapshot)

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
        }
    }
}

extension Interpreter {
    /// Lower only the proven literal-returning `Task.detached` subset. Every
    /// unsupported statement/expression shape returns nil and keeps using the
    /// cooperative evaluator; there is no best-effort worker interpretation.
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
              let expression = Self.singleExpression(in: item),
              let value = literalWorkerSnapshot(expression) else {
            return nil
        }

        let capability = try entry.makeWorkerCapability(copying: [])
        let kernel = RuntimeSourceSnapshotKernel.constant(value)
        return RuntimePhysicalWorkerJob(
            capability: capability,
            priority: priority
        ) { capability in
            try kernel.execute(with: capability)
        }
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
