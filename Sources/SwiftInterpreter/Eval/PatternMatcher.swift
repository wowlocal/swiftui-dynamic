import SwiftSyntax

/// `switch` evaluation and pattern matching: expression patterns (literals,
/// constants, ranges, enum cases), value bindings (`case let x`, `case
/// .done(let msg)`), wildcards, and tuple patterns — enough for the switches
/// real SwiftUI view code writes.
extension Interpreter {
    func executeSwitch(_ switchExpr: SwitchExprSyntax, in env: Environment) throws -> StatementResult {
        var selected = try selectCase(switchExpr, in: env)
        while true {
            let falls = Self.trailingFallthrough(selected.statements)
            let body = falls
                ? CodeBlockItemListSyntax(Array(selected.statements.dropLast()))
                : selected.statements
            let result = try executeBlock(body, in: selected.env)
            if case .breakLoop = result {
                return .normal(.void) // `break` inside a case exits the SWITCH
            }
            if falls, case .normal = result,
               let next = caseStatements(after: selected.caseIndex, in: switchExpr) {
                // `fallthrough` runs the NEXT case's body, no re-match.
                selected = (next.index, next.statements, Environment(parent: env))
                continue
            }
            return result
        }
    }

    func collectBuilderSwitch(_ switchExpr: SwitchExprSyntax, in env: Environment) throws -> [RuntimeValue] {
        var selected = try selectCase(switchExpr, in: env)
        var views: [RuntimeValue] = []
        while true {
            let falls = Self.trailingFallthrough(selected.statements)
            let body = falls
                ? CodeBlockItemListSyntax(Array(selected.statements.dropLast()))
                : selected.statements
            views += try collectBuilderViews(body, in: selected.env)
            if falls, let next = caseStatements(after: selected.caseIndex, in: switchExpr) {
                selected = (next.index, next.statements, Environment(parent: env))
                continue
            }
            return views
        }
    }

    func collectResultBuilderSwitch(
        _ switchExpression: SwitchExprSyntax,
        in env: Environment,
        resultProtocol: String
    ) throws -> [RuntimeValue] {
        var selected = try selectCase(switchExpression, in: env)
        var values: [RuntimeValue] = []
        while true {
            let falls = Self.trailingFallthrough(selected.statements)
            let body = falls
                ? CodeBlockItemListSyntax(
                    Array(selected.statements.dropLast()))
                : selected.statements
            values += try collectResultBuilderValues(
                body,
                in: selected.env,
                resultProtocol: resultProtocol)
            if falls,
               let next = caseStatements(
                    after: selected.caseIndex,
                    in: switchExpression) {
                selected = (
                    next.index,
                    next.statements,
                    Environment(parent: env))
                continue
            }
            return values
        }
    }

    /// Swift requires `fallthrough` to be the LAST statement of a case.
    static func trailingFallthrough(_ statements: CodeBlockItemListSyntax) -> Bool {
        guard let last = statements.last, case .stmt(let stmt) = last.item else { return false }
        return stmt.is(FallThroughStmtSyntax.self)
    }

    /// Switch arms with `#if` blocks expanded to their active clause
    /// (amperfy gates a `case .developer:` arm — and the enum case itself —
    /// behind `#if DEBUG`). Indices into this array are the caseIndex
    /// currency `fallthrough` navigation uses.
    func flattenedSwitchCases(_ switchExpr: SwitchExprSyntax) -> [SwitchCaseSyntax] {
        flattenSwitchCaseList(switchExpr.cases)
    }

    private func flattenSwitchCaseList(_ list: SwitchCaseListSyntax) -> [SwitchCaseSyntax] {
        var result: [SwitchCaseSyntax] = []
        for element in list {
            switch element {
            case .switchCase(let switchCase):
                result.append(switchCase)
            case .ifConfigDecl(let ifConfig):
                if let clause = activeIfConfigClause(ifConfig),
                   case .switchCases(let nested)? = clause.elements {
                    result.append(contentsOf: flattenSwitchCaseList(nested))
                }
            }
        }
        return result
    }

    func caseStatements(
        after index: Int, in switchExpr: SwitchExprSyntax
    ) -> (index: Int, statements: CodeBlockItemListSyntax)? {
        let elements = flattenedSwitchCases(switchExpr)
        let cursor = index + 1
        guard cursor < elements.count else { return nil }
        return (cursor, elements[cursor].statements)
    }

    private func selectCase(
        _ switchExpr: SwitchExprSyntax,
        in env: Environment
    ) throws -> (caseIndex: Int, statements: CodeBlockItemListSyntax, env: Environment) {
        let subject = try evaluate(switchExpr.subject, in: env)
        var defaultCase: (Int, CodeBlockItemListSyntax)?
        let cases = flattenedSwitchCases(switchExpr)

        for (index, switchCase) in cases.enumerated() {
            switch switchCase.label {
            case .default:
                defaultCase = (index, switchCase.statements)
            case .case(let label):
                for item in label.caseItems {
                    let child = Environment(parent: env)
                    guard try matches(item.pattern, subject: subject, bindingInto: child, env: env) else { continue }
                    if let whereClause = item.whereClause {
                        guard try expectBool(evaluate(whereClause.condition, in: child), node: whereClause.condition) else {
                            continue
                        }
                    }
                    return (index, switchCase.statements, child)
                }
            }
        }
        if let (index, statements) = defaultCase {
            return (index, statements, Environment(parent: env))
        }
        // A default-less switch over an UNKNOWABLE subject: real code is
        // exhaustive over a real value; the fresh reading is the FIRST case
        // (the same doctrine as synthesis picking the first enum case),
        // with payload bindings bound to unknowable chains.
        if isUnknowable(subject) {
            for (index, switchCase) in cases.enumerated() {
                guard case .case(let label) = switchCase.label,
                      let item = label.caseItems.first else { continue }
                let child = Environment(parent: env)
                bindPatternsToUnknowables(item.pattern, into: child)
                return (index, switchCase.statements, child)
            }
        }
        throw error(switchExpr, "switch was not exhaustive for \(subject.stringified)")
    }

    func isUnknowable(_ value: RuntimeValue) -> Bool {
        if case .host(let any) = value {
            return any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall
        }
        if case .implicitMember = value { return true }
        if case .hostFunction = value { return true }
        return false
    }

    /// `case .selection(let range):` chosen as the fresh branch — its
    /// bindings read unknowable chains that absorb downstream.
    func bindPatternsToUnknowables(_ pattern: PatternSyntax, into env: Environment) {
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
        env: Environment,
        declaredTypeName: String? = nil
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
            return try matches(
                binding.pattern, subject: subject,
                bindingInto: bindings, env: env,
                declaredTypeName: declaredTypeName)
        }
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            // Reached only under `let`/`var` — bare constants parse as expression patterns.
            bindings.define(
                ident.identifier.text, subject,
                declaredTypeName: declaredTypeName)
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

    /// `let file as String` inside a pattern parses as an UNFOLDED sequence.
    /// Declared source types are checkable and must really match; opaque host
    /// shapes retain the interpreter's documented optimistic-cast fallback.
    private func matchCastSequence(
        _ expr: ExprSyntax, subject: RuntimeValue, bindingInto bindings: Environment
    ) -> Bool? {
        // Folded (`AsExpr(PatternExpr(text), String)`) and unfolded
        // sequences both appear depending on the folder's reach.
        var target: ExprSyntax?
        var castType: String?
        if let asExpr = expr.as(AsExprSyntax.self) {
            target = asExpr.expression
            castType = asExpr.type.trimmedDescription
        } else if let seq = expr.as(SequenceExprSyntax.self) {
            let items = Array(seq.elements)
            guard items.count == 3, items[1].is(UnresolvedAsExprSyntax.self) else { return nil }
            target = items[0]
            castType = items[2].as(TypeExprSyntax.self)?.type.trimmedDescription
        }
        guard let target else { return nil }
        if subject.isNil { return false }
        if let castType {
            var typeName = castType
            while typeName.hasSuffix("?") || typeName.hasSuffix("!") {
                typeName = String(typeName.dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }
            let sourceSubject: Bool
            switch subject {
            case .instance, .enumCase: sourceSubject = true
            default: sourceSubject = false
            }
            let declaredTarget = typeValue(named: typeName) != nil
                || protocolInheritance[typeName] != nil
            if sourceSubject, declaredTarget,
               !valueIsType(subject, typeName) {
                return false
            }

            // Primitive casts are checkable too: `for case let text as
            // String` over `[Any]` must skip the Ints.
            if let any = subject.hostPayload {
                switch typeName {
            case "String": guard any is String else { return false }
            case "Int": guard any is Int else { return false }
            case "Double", "CGFloat", "TimeInterval": guard any is Double || any is Int else { return false }
            case "Bool": guard any is Bool else { return false }
            default: break
                }
            }
        }
        if let ref = target.as(DeclReferenceExprSyntax.self) {
            bindings.define(ref.baseName.text, subject)
            return true
        }
        if let patternExpr = target.as(PatternExprSyntax.self) {
            var inner = patternExpr.pattern
            if let binding = inner.as(ValueBindingPatternSyntax.self) { inner = binding.pattern }
            if let ident = inner.as(IdentifierPatternSyntax.self) {
                bindings.define(ident.identifier.text, subject)
                return true
            }
            if inner.is(WildcardPatternSyntax.self) { return true }
        }
        if target.is(DiscardAssignmentExprSyntax.self) { return true }
        return nil
    }

    private func matchExpression(
        _ expr: ExprSyntax,
        subject: RuntimeValue,
        bindingInto bindings: Environment,
        env: Environment
    ) throws -> Bool {
        if let cast = matchCastSequence(expr, subject: subject, bindingInto: bindings) {
            return cast
        }
        // `case let value?` is represented by SwiftSyntax as an expression
        // pattern whose expression is OptionalChainingExpr. It unwraps one
        // layer and applies/binds the inner pattern.
        if let optionalPattern = expr.as(OptionalChainingExprSyntax.self) {
            guard case .some(let wrapped, let wrappedTypeName) =
                    subject.optionalState else {
                return false
            }
            let inner = optionalPattern.expression
            if let patternExpression = inner.as(PatternExprSyntax.self) {
                return try matches(
                    patternExpression.pattern, subject: wrapped,
                    bindingInto: bindings, env: env,
                    declaredTypeName: wrappedTypeName)
            }
            if let reference = inner.as(DeclReferenceExprSyntax.self) {
                bindings.define(
                    reference.baseName.text, wrapped,
                    declaredTypeName: wrappedTypeName)
                return true
            }
            if inner.is(DiscardAssignmentExprSyntax.self) { return true }
            return try matchExpression(
                inner, subject: wrapped,
                bindingInto: bindings, env: env)
        }
        // `.none` / `nil` over NATIVE optionals (payload positions recurse
        // here): matches exactly the nil subject.
        if expr.is(NilLiteralExprSyntax.self) { return subject.isNil }
        if let member = expr.as(MemberAccessExprSyntax.self), member.base == nil,
           member.declName.baseName.text == "none", caseShape(of: subject) == nil {
            return subject.isNil
        }
        // `.some(length)` / `.some(let x)` over NATIVE optionals: matches
        // when the subject holds a value, binding the inner pattern to it.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.base == nil, member.declName.baseName.text == "some",
           call.arguments.count == 1, let inner = call.arguments.first?.expression,
           caseShape(of: subject) == nil {
            guard case .some(let unwrapped, let wrappedTypeName) =
                    subject.optionalState else {
                return false
            }
            if let patternExpr = inner.as(PatternExprSyntax.self) {
                return try matches(
                    patternExpr.pattern, subject: unwrapped,
                    bindingInto: bindings, env: env,
                    declaredTypeName: wrappedTypeName)
            }
            return try matchExpression(
                inner, subject: unwrapped,
                bindingInto: bindings, env: env)
        }
        // For an Optional enum, `.case` is Swift shorthand for
        // `.some(.case)`. Keep general expression constants comparing the
        // outer Optional; only implicit enum-case spelling unwraps here.
        if case .some(let wrapped, _) = subject.optionalState {
            let isImplicitEnumCase: Bool = {
                if let member = expr.as(MemberAccessExprSyntax.self) {
                    return member.base == nil
                }
                if let call = expr.as(FunctionCallExprSyntax.self),
                   let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                    return member.base == nil
                }
                return false
            }()
            if isImplicitEnumCase, caseShape(of: wrapped) != nil {
                return try matchExpression(
                    expr, subject: wrapped,
                    bindingInto: bindings, env: env)
            }
        }
        // `case (_, .hideAll)` — tuple patterns in expression form match
        // ELEMENTWISE; `_` is the wildcard.
        if expr.is(DiscardAssignmentExprSyntax.self) { return true }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count > 1,
           let subjectTuple = subject.tupleValue,
           tuple.elements.count == subjectTuple.values.count {
            for (element, value) in zip(tuple.elements, subjectTuple.values) {
                guard try matchExpression(element.expression, subject: value, bindingInto: bindings, env: env) else {
                    return false
                }
            }
            return true
        }
        // Bare `case .error:` — compiled Swift lets a payload case be matched
        // by its payload-less spelling; only the case NAME is checked.
        if let member = expr.as(MemberAccessExprSyntax.self),
           let (caseName, _, _) = caseShape(of: subject),
           member.declName.baseName.text == caseName {
            return true
        }
        // `.finished(let message)` / `Status.finished(let message)` — enum
        // payload patterns arrive as call expressions whose arguments may be
        // nested patterns. Subjects that never got type context arrive as
        // ImplicitMemberCall natives; treat them like cases too.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let (caseName, payloads, payloadTypeNames) = caseShape(of: subject) {
            guard caseName == member.declName.baseName.text,
                  payloads.count == call.arguments.count else { return false }
            for (index, pair) in zip(call.arguments, payloads).enumerated() {
                let (argument, payload) = pair
                let payloadTypeName = payloadTypeNames.indices.contains(index)
                    ? payloadTypeNames[index] : nil
                // `case .display(let items, _)` — a payload wildcard.
                if argument.expression.is(DiscardAssignmentExprSyntax.self) { continue }
                if let patternExpr = argument.expression.as(PatternExprSyntax.self) {
                    guard try matches(
                        patternExpr.pattern, subject: payload,
                        bindingInto: bindings, env: env,
                        declaredTypeName: payloadTypeName
                    ) else {
                        return false
                    }
                } else if argument.expression.is(FunctionCallExprSyntax.self)
                    || argument.expression.is(MemberAccessExprSyntax.self)
                    || argument.expression.is(TupleExprSyntax.self) {
                    // NESTED patterns in payload position — isowords'
                    // `case let .edges(edges, .some(length))` — recurse as
                    // patterns, never as expressions (the inner `let`
                    // bindings would be unevaluatable).
                    guard try matchExpression(argument.expression, subject: payload, bindingInto: bindings, env: env) else {
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
        return try matchRuntimePattern(value, subject: subject, env: env, node: expr)
    }

    /// Shared implementation of Swift's expression-pattern `~=` operation.
    /// Explicit `pattern ~= value` expressions call this same path.
    func matchRuntimePattern(
        _ pattern: RuntimeValue,
        subject: RuntimeValue,
        env: Environment,
        node: some SyntaxProtocol
    ) throws -> Bool {
        if let range = pattern.rangeValue {
            return try relocating(node) { try range.contains(subject) }
        }
        if let custom = try invokeCustomPatternOperator(
            pattern: pattern, subject: subject, env: env, node: node) {
            guard let result = custom.boolValue else {
                throw error(node, "custom ~= must return Bool, got \(custom.stringified)")
            }
            return result
        }
        // `case .leading:` against a HOST subject — the marker resolves
        // against the subject's type first (the infix `==` path does the
        // same adoption), so Equatable host families match natively
        // instead of falling to `default:`.
        let resolvedPattern = try adoptHostType(of: subject, for: pattern, allowCalls: true)
        return try relocating(node) { try Builtins.areEqual(subject, resolvedPattern) }
    }

    private func invokeCustomPatternOperator(
        pattern: RuntimeValue,
        subject: RuntimeValue,
        env: Environment,
        node: some SyntaxProtocol
    ) throws -> RuntimeValue? {
        let args = CallArguments(arguments: [
            .init(label: nil, value: pattern),
            .init(label: nil, value: subject),
        ])

        for operand in [pattern, subject] {
            let overloads: [FunctionDeclSyntax]?
            let home: RuntimeValue
            switch operand {
            case .instance(let instance):
                overloads = instance.symbol.staticMethods["~="]
                home = .type(instance.symbol)
            case .enumCase(let value):
                overloads = value.symbol.staticMethods["~="]
                home = .enumType(value.symbol)
            default:
                overloads = nil
                home = .void
            }
            guard let overloads else { continue }
            let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
            if let method = available.first(where: {
                let metadata = functionMetadata(for: $0)
                return metadata.shape.matches(ArgumentShape(args))
                    && runtimeArgumentsFitDeclaredTypes(
                        metadata.parameters,
                        args: args,
                        genericParameterNames: Set(metadata.genericParameters),
                        genericConformanceRequirements:
                            metadata.genericConformanceRequirements,
                        lexicalOwner: lexicalOwner(of: $0.id))
            }),
               let body = functionMetadata(for: method).body {
                let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(home))
                return try callWithArguments(closure, args: args, node: Syntax(node))
            }
        }

        if let overloads = globalFunctionOverloads["~="] {
            let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
            if let function = available.first(where: {
                let metadata = functionMetadata(for: $0)
                return metadata.shape.matches(ArgumentShape(args))
                    && runtimeArgumentsFitDeclaredTypes(
                        metadata.parameters,
                        args: args,
                        genericParameterNames: Set(metadata.genericParameters),
                        genericConformanceRequirements:
                            metadata.genericConformanceRequirements,
                        lexicalOwner: lexicalOwner(of: $0.id))
            }),
               let body = functionMetadata(for: function).body {
                let closure = makeFunctionClosure(function, body: body, captured: globals)
                return try callWithArguments(closure, args: args, node: Syntax(node))
            }
        } else if case .closure(let closure)? = env.lookup("~=") ?? globals.lookup("~=") {
            return try callWithArguments(closure, args: args, node: Syntax(node))
        }
        return nil
    }

    /// Case name + payloads for anything case-shaped: a real enum value, or a
    /// bare `.name(args)` that never received type context.
    private func caseShape(
        of subject: RuntimeValue
    ) -> (
        name: String,
        payloads: [RuntimeValue],
        payloadTypeNames: [String?]
    )? {
        if case .enumCase(let value) = subject {
            let declared = value.symbol.caseInfo(named: value.name)?
                .associatedTypeNames ?? []
            let typeNames: [String?] = value.associated.indices.map { index in
                declared.indices.contains(index) ? declared[index] : nil
            }
            return (value.name, value.associated, typeNames)
        }
        if case .host(let any) = subject, let call = any as? ImplicitMemberCall {
            let payloads = call.arguments.arguments.map(\.value)
            return (
                call.name, payloads,
                Array(repeating: nil, count: payloads.count))
        }
        if case .host(let any) = subject, let shaped = any as? CaseShaped {
            return (
                shaped.caseName, shaped.casePayloads,
                Array(repeating: nil, count: shaped.casePayloads.count))
        }
        return nil
    }
}
