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
            return .normal(try evaluate(expr, in: env))
        }
    }

    func executeDecl(_ decl: DeclSyntax, in env: Environment) throws {
        if let varDecl = decl.as(VariableDeclSyntax.self) {
            for binding in varDecl.bindings {
                guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw error(binding, "unsupported binding pattern")
                }
                guard binding.accessorBlock == nil else {
                    throw error(binding, "computed properties are only supported inside structs")
                }
                guard let initializer = binding.initializer?.value else {
                    throw error(binding, "'\(ident.identifier.text)' needs an initial value")
                }
                env.define(ident.identifier.text, try evaluate(initializer, in: env))
            }
            return
        }
        if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            try defineFunction(funcDecl, in: env)
            return
        }
        if decl.is(StructDeclSyntax.self) {
            throw error(decl, "structs must be declared at the top level")
        }
        throw error(decl, "unsupported declaration (\(decl.kind))")
    }

    private func executeStatement(_ stmt: StmtSyntax, in env: Environment) throws -> StatementResult {
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            if let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                return try executeIf(ifExpr, in: env)
            }
            return .normal(try evaluate(exprStmt.expression, in: env))
        }
        if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
            let value = try returnStmt.expression.map { try evaluate($0, in: env) } ?? .void
            return .returnValue(value)
        }
        if let forStmt = stmt.as(ForStmtSyntax.self) {
            return try executeFor(forStmt, in: env)
        }
        if let whileStmt = stmt.as(WhileStmtSyntax.self) {
            return try executeWhile(whileStmt, in: env)
        }
        if stmt.is(BreakStmtSyntax.self) { return .breakLoop }
        if stmt.is(ContinueStmtSyntax.self) { return .continueLoop }
        if stmt.is(GuardStmtSyntax.self) {
            throw error(stmt, "'guard' isn't supported yet")
        }
        throw error(stmt, "unsupported statement (\(stmt.kind))")
    }

    func executeIf(_ ifExpr: IfExprSyntax, in env: Environment) throws -> StatementResult {
        if try conditionsHold(ifExpr.conditions, in: env) {
            return try executeBlock(ifExpr.body.statements, in: Environment(parent: env))
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

    func conditionsHold(_ conditions: ConditionElementListSyntax, in env: Environment) throws -> Bool {
        for element in conditions {
            guard case .expression(let condition) = element.condition else {
                throw error(element, "only boolean conditions are supported (no optional binding)")
            }
            guard try expectBool(evaluate(condition, in: env), node: condition) else { return false }
        }
        return true
    }

    private func executeFor(_ forStmt: ForStmtSyntax, in env: Environment) throws -> StatementResult {
        guard let ident = forStmt.pattern.as(IdentifierPatternSyntax.self) else {
            throw error(forStmt.pattern, "only simple for-in patterns are supported")
        }
        let name = ident.identifier.text
        let sequence = try evaluate(forStmt.sequence, in: env)

        let elements: [RuntimeValue]
        if case .native(let any) = sequence, let range = any as? Range<Int> {
            elements = range.map { .native($0) }
        } else if let array = sequence.arrayValue {
            elements = array
        } else {
            throw error(forStmt.sequence, "for-in requires a range or an array")
        }

        loop: for element in elements {
            try tick(forStmt)
            let child = Environment(parent: env)
            child.define(name, element)
            let result = try executeBlock(forStmt.body.statements, in: child)
            switch result {
            case .normal: continue
            case .continueLoop: continue
            case .breakLoop: break loop
            case .returnValue: return result
            }
        }
        return .normal(.void)
    }

    private func executeWhile(_ whileStmt: WhileStmtSyntax, in env: Environment) throws -> StatementResult {
        while try conditionsHold(whileStmt.conditions, in: env) {
            try tick(whileStmt)
            let result = try executeBlock(whileStmt.body.statements, in: Environment(parent: env))
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
    /// collected instead of discarded; `if` contributes its branch's views;
    /// `let` bindings are allowed. Interpreted View instances are wrapped
    /// renderable on the way in.
    func collectBuilderViews(_ items: CodeBlockItemListSyntax, in env: Environment) throws -> [RuntimeValue] {
        var views: [RuntimeValue] = []
        for item in items {
            try tick(item)
            switch item.item {
            case .decl(let decl):
                try executeDecl(decl, in: env)
            case .stmt(let stmt):
                if let exprStmt = stmt.as(ExpressionStmtSyntax.self),
                   let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                    views += try collectBuilderIf(ifExpr, in: env)
                } else {
                    throw error(stmt, "unsupported statement in a view builder (\(stmt.kind))")
                }
            case .expr(let expr):
                if let ifExpr = expr.as(IfExprSyntax.self) {
                    views += try collectBuilderIf(ifExpr, in: env)
                } else {
                    appendViewValue(try evaluate(expr, in: env), to: &views)
                }
            }
        }
        return views
    }

    private func collectBuilderIf(_ ifExpr: IfExprSyntax, in env: Environment) throws -> [RuntimeValue] {
        if try conditionsHold(ifExpr.conditions, in: env) {
            return try collectBuilderViews(ifExpr.body.statements, in: Environment(parent: env))
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

    private func appendViewValue(_ value: RuntimeValue, to views: inout [RuntimeValue]) {
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
