import SwiftSyntax

/// `switch` evaluation and pattern matching: expression patterns (literals,
/// constants, ranges, enum cases), value bindings (`case let x`, `case
/// .done(let msg)`), wildcards, and tuple patterns — enough for the switches
/// real SwiftUI view code writes.
extension Interpreter {
    func executeSwitch(_ switchExpr: SwitchExprSyntax, in env: Environment) throws -> StatementResult {
        let selected = try selectCase(switchExpr, in: env)
        let result = try executeBlock(selected.statements, in: selected.env)
        if case .breakLoop = result {
            return .normal(.void) // `break` inside a case exits the SWITCH
        }
        return result
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
        // A default-less switch over an UNKNOWABLE subject: real code is
        // exhaustive over a real value; the fresh reading is the FIRST case
        // (the same doctrine as synthesis picking the first enum case),
        // with payload bindings bound to unknowable chains.
        if isUnknowable(subject) {
            for element in switchExpr.cases {
                guard case .switchCase(let switchCase) = element,
                      case .case(let label) = switchCase.label,
                      let item = label.caseItems.first else { continue }
                let child = Environment(parent: env)
                bindPatternsToUnknowables(item.pattern, into: child)
                return (switchCase.statements, child)
            }
        }
        throw error(switchExpr, "switch was not exhaustive for \(subject.stringified)")
    }

    private func isUnknowable(_ value: RuntimeValue) -> Bool {
        if case .native(let any) = value {
            return any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall
        }
        if case .implicitMember = value { return true }
        if case .hostFunction = value { return true }
        return false
    }

    /// `case .selection(let range):` chosen as the fresh branch — its
    /// bindings read unknowable chains that absorb downstream.
    private func bindPatternsToUnknowables(_ pattern: PatternSyntax, into env: Environment) {
        if let binding = pattern.as(ValueBindingPatternSyntax.self) {
            bindPatternsToUnknowables(binding.pattern, into: env)
            return
        }
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            env.define(ident.identifier.text, .native(ChainedImplicitCall(
                base: .implicitMember("fresh"), member: ident.identifier.text,
                arguments: CallArguments())))
            return
        }
        if let expr = pattern.as(ExpressionPatternSyntax.self),
           let call = expr.expression.as(FunctionCallExprSyntax.self) {
            for argument in call.arguments {
                if let inner = argument.expression.as(PatternExprSyntax.self) {
                    bindPatternsToUnknowables(inner.pattern, into: env)
                }
            }
        }
    }

    func matches(
        _ pattern: PatternSyntax,
        subject: RuntimeValue,
        bindingInto bindings: Environment,
        env: Environment
    ) throws -> Bool {
        if pattern.is(WildcardPatternSyntax.self) { return true }

        // Switching over a nil optional: `case .none` / `case nil` match,
        // any other case shape doesn't.
        if subject.isNil, let expr = pattern.as(ExpressionPatternSyntax.self) {
            if expr.expression.is(NilLiteralExprSyntax.self) { return true }
            if let member = expr.expression.as(MemberAccessExprSyntax.self),
               member.base == nil, member.declName.baseName.text == "none" {
                return true
            }
            return false
        }

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

        // Case-shaped pattern (payload bindings inside) against a subject
        // with no case shape — host markers, fresh-state stubs: it can't
        // match, so the switch falls to `default` (the fresh-state read).
        // Evaluating it as an expression would choke on the `let` bindings.
        if let call = expr.as(FunctionCallExprSyntax.self),
           call.calledExpression.is(MemberAccessExprSyntax.self),
           call.arguments.contains(where: { $0.expression.is(PatternExprSyntax.self) }) {
            return false
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
