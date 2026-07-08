import SwiftSyntax

/// `switch` evaluation and pattern matching: expression patterns (literals,
/// constants, ranges, enum cases), value bindings (`case let x`, `case
/// .done(let msg)`), wildcards, and tuple patterns — enough for the switches
/// real SwiftUI view code writes.
extension Interpreter {
    func executeSwitch(_ switchExpr: SwitchExprSyntax, in env: Environment) throws -> StatementResult {
        let selected = try selectCase(switchExpr, in: env)
        return try executeBlock(selected.statements, in: selected.env)
    }

    func collectBuilderSwitch(_ switchExpr: SwitchExprSyntax, in env: Environment) throws -> [RuntimeValue] {
        let selected = try selectCase(switchExpr, in: env)
        return try collectBuilderViews(selected.statements, in: selected.env)
    }

    private func selectCase(
        _ switchExpr: SwitchExprSyntax,
        in env: Environment
    ) throws -> (statements: CodeBlockItemListSyntax, env: Environment) {
        let subject = try evaluate(switchExpr.subject, in: env)
        var defaultCase: CodeBlockItemListSyntax?

        for element in switchExpr.cases {
            guard case .switchCase(let switchCase) = element else { continue }
            switch switchCase.label {
            case .default:
                defaultCase = switchCase.statements
            case .case(let label):
                for item in label.caseItems {
                    let child = Environment(parent: env)
                    guard try matches(item.pattern, subject: subject, bindingInto: child, env: env) else { continue }
                    if let whereClause = item.whereClause {
                        guard try expectBool(evaluate(whereClause.condition, in: child), node: whereClause.condition) else {
                            continue
                        }
                    }
                    return (switchCase.statements, child)
                }
            }
        }
        if let defaultCase {
            return (defaultCase, Environment(parent: env))
        }
        throw error(switchExpr, "switch was not exhaustive for \(subject.stringified)")
    }

    func matches(
        _ pattern: PatternSyntax,
        subject: RuntimeValue,
        bindingInto bindings: Environment,
        env: Environment
    ) throws -> Bool {
        if pattern.is(WildcardPatternSyntax.self) { return true }

        if let binding = pattern.as(ValueBindingPatternSyntax.self) {
            return try matches(binding.pattern, subject: subject, bindingInto: bindings, env: env)
        }
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            // Reached only under `let`/`var` — bare constants parse as expression patterns.
            bindings.define(ident.identifier.text, subject)
            return true
        }
        if let tuplePattern = pattern.as(TuplePatternSyntax.self), let tuple = subject.tupleValue {
            guard tuplePattern.elements.count == tuple.values.count else { return false }
            for (element, value) in zip(tuplePattern.elements, tuple.values) {
                guard try matches(element.pattern, subject: value, bindingInto: bindings, env: env) else { return false }
            }
            return true
        }
        if let exprPattern = pattern.as(ExpressionPatternSyntax.self) {
            return try matchExpression(exprPattern.expression, subject: subject, bindingInto: bindings, env: env)
        }
        throw error(pattern, "unsupported pattern (\(pattern.kind))")
    }

    private func matchExpression(
        _ expr: ExprSyntax,
        subject: RuntimeValue,
        bindingInto bindings: Environment,
        env: Environment
    ) throws -> Bool {
        // `.finished(let message)` / `Status.finished(let message)` — enum
        // payload patterns arrive as call expressions whose arguments may be
        // nested patterns. Subjects that never got type context arrive as
        // ImplicitMemberCall natives; treat them like cases too.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let (caseName, payloads) = caseShape(of: subject) {
            guard caseName == member.declName.baseName.text,
                  payloads.count == call.arguments.count else { return false }
            for (argument, payload) in zip(call.arguments, payloads) {
                if let patternExpr = argument.expression.as(PatternExprSyntax.self) {
                    guard try matches(patternExpr.pattern, subject: payload, bindingInto: bindings, env: env) else {
                        return false
                    }
                } else {
                    let expected = try evaluate(argument.expression, in: env)
                    let equal = try relocating(argument.expression) { try Builtins.areEqual(expected, payload) }
                    guard equal else { return false }
                }
            }
            return true
        }

        let value = try evaluate(expr, in: env)
        if let range = value.rangeValue, let i = subject.intValue {
            return range.contains(i)
        }
        return try relocating(expr) { try Builtins.areEqual(subject, value) }
    }

    /// Case name + payloads for anything case-shaped: a real enum value, or a
    /// bare `.name(args)` that never received type context.
    private func caseShape(of subject: RuntimeValue) -> (name: String, payloads: [RuntimeValue])? {
        if case .enumCase(let value) = subject {
            return (value.name, value.associated)
        }
        if case .native(let any) = subject, let call = any as? ImplicitMemberCall {
            return (call.name, call.arguments.arguments.map(\.value))
        }
        return nil
    }
}
