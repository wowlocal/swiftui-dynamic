import SwiftSyntax

/// How a statement finished. Control flow propagates as values instead of
/// thrown errors: blocks stop and pass `.returnValue`/`.breakLoop`/`.continueLoop`
/// upward until a loop or function boundary consumes them.
enum StatementResult {
    case normal(RuntimeValue)
    case returnValue(RuntimeValue)
    case breakLoop
    case continueLoop
}

extension Interpreter {
    /// Execute a block; the `.normal` payload is the value of the last
    /// expression statement (which is what gives closures implicit returns).
    func executeBlock(_ items: CodeBlockItemListSyntax, in env: Environment) throws -> StatementResult {
        var last: RuntimeValue = .void
        for item in items {
            let result = try execute(item, in: env)
            guard case .normal(let value) = result else { return result }
            last = value
        }
        return .normal(last)
    }

    func execute(_ item: CodeBlockItemSyntax, in env: Environment) throws -> StatementResult {
        try tick(item)
        switch item.item {
        case .decl(let decl):
            try executeDecl(decl, in: env)
            return .normal(.void)
        case .stmt(let stmt):
            return try executeStatement(stmt, in: env)
        case .expr(let expr):
            if let ifExpr = expr.as(IfExprSyntax.self) {
                return try executeIf(ifExpr, in: env)
            }
            if let switchExpr = expr.as(SwitchExprSyntax.self) {
                return try executeSwitch(switchExpr, in: env)
            }
            return .normal(try evaluate(expr, in: env))
        }
    }

    func executeDecl(_ decl: DeclSyntax, in env: Environment) throws {
        if decl.is(MacroExpansionDeclSyntax.self) {
            return // #Preview and friends are inert at runtime
        }
        if let varDecl = decl.as(VariableDeclSyntax.self) {
            for binding in varDecl.bindings {
                guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw error(binding, "unsupported binding pattern")
                }
                guard binding.accessorBlock == nil else {
                    throw error(binding, "computed properties are only supported inside types")
                }
                guard let initializer = binding.initializer?.value else {
                    throw error(binding, "'\(ident.identifier.text)' needs an initial value")
                }
                let value = try evaluate(initializer, in: env)
                env.define(ident.identifier.text, resolveAnnotated(value, annotation: binding.typeAnnotation?.type))
            }
            return
        }
        if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            try defineFunction(funcDecl, in: env)
            return
        }
        if decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self)
            || decl.is(EnumDeclSyntax.self) || decl.is(ExtensionDeclSyntax.self) {
            throw error(decl, "types must be declared at the top level")
        }
        throw error(decl, "unsupported declaration (\(decl.kind))")
    }

    private func executeStatement(_ stmt: StmtSyntax, in env: Environment) throws -> StatementResult {
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            if let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                return try executeIf(ifExpr, in: env)
            }
            if let switchExpr = exprStmt.expression.as(SwitchExprSyntax.self) {
                return try executeSwitch(switchExpr, in: env)
            }
            return .normal(try evaluate(exprStmt.expression, in: env))
        }
        if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
            let value = try returnStmt.expression.map { try evaluate($0, in: env) } ?? .void
            return .returnValue(value)
        }
        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            return try executeGuard(guardStmt, in: env)
        }
        if let forStmt = stmt.as(ForStmtSyntax.self) {
            return try executeFor(forStmt, in: env)
        }
        if let whileStmt = stmt.as(WhileStmtSyntax.self) {
            return try executeWhile(whileStmt, in: env)
        }
        if stmt.is(BreakStmtSyntax.self) { return .breakLoop }
        if stmt.is(ContinueStmtSyntax.self) { return .continueLoop }
        throw error(stmt, "unsupported statement (\(stmt.kind))")
    }

    // MARK: - Conditions (boolean + optional binding)

    /// Evaluates a condition list. `if let`/`guard let` bindings are defined
    /// into `bindings` (the success-branch scope) as they succeed.
    func conditionsHold(_ conditions: ConditionElementListSyntax, in env: Environment, bindingInto bindings: Environment) throws -> Bool {
        for element in conditions {
            switch element.condition {
            case .expression(let condition):
                guard try expectBool(evaluate(condition, in: bindings), node: condition) else { return false }
            case .optionalBinding(let optionalBinding):
                guard let ident = optionalBinding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw error(optionalBinding, "unsupported optional-binding pattern")
                }
                let name = ident.identifier.text
                let value: RuntimeValue
                if let initializer = optionalBinding.initializer?.value {
                    value = try evaluate(initializer, in: bindings)
                } else {
                    // `if let x` shorthand
                    value = try resolveIdentifier(name, in: bindings, node: optionalBinding)
                }
                guard !value.isNil else { return false }
                bindings.define(name, value)
            default:
                throw error(element, "unsupported condition (case patterns aren't supported)")
            }
        }
        return true
    }

    func executeIf(_ ifExpr: IfExprSyntax, in env: Environment) throws -> StatementResult {
        let child = Environment(parent: env)
        if try conditionsHold(ifExpr.conditions, in: env, bindingInto: child) {
            return try executeBlock(ifExpr.body.statements, in: child)
        }
        switch ifExpr.elseBody {
        case .none:
            return .normal(.void)
        case .codeBlock(let block):
            return try executeBlock(block.statements, in: Environment(parent: env))
        case .ifExpr(let nested):
            return try executeIf(nested, in: env)
        }
    }

    private func executeGuard(_ guardStmt: GuardStmtSyntax, in env: Environment) throws -> StatementResult {
        // Guard bindings live in the ENCLOSING scope on success.
        if try conditionsHold(guardStmt.conditions, in: env, bindingInto: env) {
            return .normal(.void)
        }
        let result = try executeBlock(guardStmt.body.statements, in: Environment(parent: env))
        if case .normal = result {
            throw error(guardStmt, "guard else must exit (return, break, or continue)")
        }
        return result
    }

    private func executeFor(_ forStmt: ForStmtSyntax, in env: Environment) throws -> StatementResult {
        let name: String?
        if let ident = forStmt.pattern.as(IdentifierPatternSyntax.self) {
            name = ident.identifier.text
        } else if forStmt.pattern.is(WildcardPatternSyntax.self) {
            name = nil // `for _ in …`
        } else {
            throw error(forStmt.pattern, "only simple for-in patterns are supported")
        }
        let sequence = try evaluate(forStmt.sequence, in: env)

        let elements: [RuntimeValue]
        if let range = sequence.rangeValue {
            elements = range.map { .native($0) }
        } else if let array = sequence.arrayValue {
            elements = array
        } else {
            throw error(forStmt.sequence, "for-in requires a range or an array")
        }

        loop: for element in elements {
            try tick(forStmt)
            let child = Environment(parent: env)
            if let name { child.define(name, element) }
            let result = try executeBlock(forStmt.body.statements, in: child)
            switch result {
            case .normal, .continueLoop: continue
            case .breakLoop: break loop
            case .returnValue: return result
            }
        }
        return .normal(.void)
    }

    private func executeWhile(_ whileStmt: WhileStmtSyntax, in env: Environment) throws -> StatementResult {
        while true {
            try tick(whileStmt)
            let child = Environment(parent: env)
            guard try conditionsHold(whileStmt.conditions, in: env, bindingInto: child) else { break }
            let result = try executeBlock(whileStmt.body.statements, in: child)
            switch result {
            case .normal, .continueLoop: continue
            case .breakLoop: return .normal(.void)
            case .returnValue: return result
            }
        }
        return .normal(.void)
    }

    // MARK: - ViewBuilder mode

    /// Evaluate a block as ViewBuilder content: each item's view value is
    /// collected instead of discarded; `if`/`switch` contribute the taken
    /// branch's views; `let` bindings are allowed. Interpreted View instances
    /// are wrapped renderable on the way in.
    func collectBuilderViews(_ items: CodeBlockItemListSyntax, in env: Environment) throws -> [RuntimeValue] {
        var views: [RuntimeValue] = []
        for item in items {
            try tick(item)
            switch item.item {
            case .decl(let decl):
                try executeDecl(decl, in: env)
            case .stmt(let stmt):
                if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
                    if let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                        views += try collectBuilderIf(ifExpr, in: env)
                        continue
                    }
                    if let switchExpr = exprStmt.expression.as(SwitchExprSyntax.self) {
                        views += try collectBuilderSwitch(switchExpr, in: env)
                        continue
                    }
                }
                if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
                    // Explicit `return someView` inside a builder-ish body.
                    if let expr = returnStmt.expression {
                        appendViewValue(try evaluate(expr, in: env), to: &views)
                    }
                    continue
                }
                throw error(stmt, "unsupported statement in a view builder (\(stmt.kind))")
            case .expr(let expr):
                if let ifExpr = expr.as(IfExprSyntax.self) {
                    views += try collectBuilderIf(ifExpr, in: env)
                } else if let switchExpr = expr.as(SwitchExprSyntax.self) {
                    views += try collectBuilderSwitch(switchExpr, in: env)
                } else {
                    appendViewValue(try evaluate(expr, in: env), to: &views)
                }
            }
        }
        return views
    }

    private func collectBuilderIf(_ ifExpr: IfExprSyntax, in env: Environment) throws -> [RuntimeValue] {
        let child = Environment(parent: env)
        if try conditionsHold(ifExpr.conditions, in: env, bindingInto: child) {
            return try collectBuilderViews(ifExpr.body.statements, in: child)
        }
        switch ifExpr.elseBody {
        case .none:
            return []
        case .codeBlock(let block):
            return try collectBuilderViews(block.statements, in: Environment(parent: env))
        case .ifExpr(let nested):
            return try collectBuilderIf(nested, in: env)
        }
    }

    func appendViewValue(_ value: RuntimeValue, to views: inout [RuntimeValue]) {
        switch value {
        case .void:
            break
        case .instance(let instance) where instance.symbol.conformsToView:
            if let registry {
                views.append(registry.makeRenderable(instance: instance, interpreter: self))
            } else {
                views.append(value)
            }
        default:
            views.append(value)
        }
    }
}
