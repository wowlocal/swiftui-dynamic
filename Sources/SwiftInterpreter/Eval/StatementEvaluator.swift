import Foundation
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
        var deferredBodies: [CodeBlockItemListSyntax] = []
        // Interpreted `defer` bodies run LIFO on every exit path (normal,
        // return/break/continue, interpreted throw). Like real Swift, a
        // defer body itself cannot redirect control flow outward.
        defer {
            for body in deferredBodies.reversed() {
                _ = try? executeBlock(body, in: env)
            }
        }
        for item in items {
            if case .stmt(let stmt) = item.item, let deferStmt = stmt.as(DeferStmtSyntax.self) {
                deferredBodies.append(deferStmt.body.statements)
                continue
            }
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
            if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                // `#if os(iOS)` — the active clause's statements run inline
                // (control flow propagates).
                if let clause = activeIfConfigClause(ifConfig),
                   case .statements(let items)? = clause.elements {
                    return try executeBlock(items, in: env)
                }
                return .normal(.void)
            }
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
            if let macro = expr.as(MacroExpansionExprSyntax.self) {
                if macro.macroName.text == "function" {
                    return .normal(try evaluate(expr, in: env))
                }
                // Registered macros (#expect/#require) execute for effect;
                // statement-position #Preview {} stays inert.
                _ = try invokeRegisteredMacro(
                    named: macro.macroName.text, arguments: macro.arguments,
                    trailingClosure: macro.trailingClosure,
                    additionalTrailingClosures: macro.additionalTrailingClosures,
                    node: macro, in: env)
                return .normal(.void)
            }
            return .normal(try evaluate(expr, in: env))
        }
    }

    func executeDecl(_ decl: DeclSyntax, in env: Environment) throws {
        if let macroDecl = decl.as(MacroExpansionDeclSyntax.self) {
            // A bare `#expect(...)` in statement position parses as a DECL —
            // registered macros execute; #Preview and friends stay inert.
            _ = try invokeRegisteredMacro(
                named: macroDecl.macroName.text, arguments: macroDecl.arguments,
                trailingClosure: macroDecl.trailingClosure,
                additionalTrailingClosures: macroDecl.additionalTrailingClosures,
                node: macroDecl, in: env)
            return
        }
        if let varDecl = decl.as(VariableDeclSyntax.self) {
            // `var igneous, memberID, passHash: String?` — annotation-less
            // bindings share the NEXT annotation in their run (initializers
            // break the run).
            let allBindings = Array(varDecl.bindings)
            let referenceOwnership = ReferenceOwnership(modifiers: varDecl.modifiers)
            func sharedAnnotation(startingAt index: Int) -> TypeSyntax? {
                for later in allBindings[index...] {
                    if let type = later.typeAnnotation?.type { return type }
                    if later.initializer != nil { return nil }
                }
                return nil
            }
            for (bindingIndex, binding) in allBindings.enumerated() {
                // `let _ = sideEffect()` — evaluate for effect, no binding.
                if binding.pattern.is(WildcardPatternSyntax.self) {
                    if let initializer = binding.initializer?.value {
                        _ = try evaluate(initializer, in: env)
                    }
                    continue
                }
                // `var (r, g, b, a) = (0, 0, 0, 0)` — tuple destructuring.
                if let tuplePattern = binding.pattern.as(TuplePatternSyntax.self),
                   let initializer = binding.initializer?.value {
                    let value = try evaluate(initializer, in: env)
                    guard let tuple = value.tupleValue,
                          tuple.values.count == tuplePattern.elements.count else {
                        throw error(binding, "tuple binding doesn't match the value shape")
                    }
                    for (element, elementValue) in zip(tuplePattern.elements, tuple.values) {
                        if let ident = element.pattern.as(IdentifierPatternSyntax.self) {
                            env.define(ident.identifier.text, elementValue)
                        }
                    }
                    continue
                }
                guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw error(binding, "unsupported binding pattern")
                }
                if let accessorBlock = binding.accessorBlock {
                    // LOCAL computed vars (`var placement: ToolbarItemPlacement
                    // { #if os(iOS) .navigation … }`): the getter evaluates
                    // once at declaration, in the CURRENT scope (locals are
                    // in reach; there's no self mutation to track).
                    guard let accessors = parseAccessors(of: accessorBlock) else {
                        throw error(binding, "unsupported accessor block on local binding")
                    }
                    let result = try executeBlock(accessors.getter, in: Environment(parent: env))
                    switch result {
                    case .normal(let value), .returnValue(let value):
                        let typeName = binding.typeAnnotation?.type.trimmedDescription
                        env.define(
                            ident.identifier.text,
                            try resolveAnnotated(value, annotation: binding.typeAnnotation?.type),
                            declaredTypeName: typeName)
                    default:
                        throw error(binding, "control flow escaped local computed var")
                    }
                    continue
                }
                guard let initializer = binding.initializer?.value else {
                    // Local DI-wrapper declarations (`@Dependency(\.workspacePool)
                    // var workspacePool`): the container provides a shared
                    // instance — the missing-environment synthesis doctrine
                    // gives a fresh model of the keypath'd type; unknown
                    // types absorb.
                    if let injected = try localDependencyValue(varDecl, in: env) {
                        env.define(ident.identifier.text, injected)
                        continue
                    }
                    let annotationText = (binding.typeAnnotation?.type ?? sharedAnnotation(startingAt: bindingIndex))?
                        .trimmedDescription ?? ""
                    if RuntimeOptionalValue.wrappedType(in: annotationText) != nil {
                        env.define(
                            ident.identifier.text,
                            .none(forTypeAnnotation: annotationText),
                            declaredTypeName: annotationText,
                            referenceOwnership: referenceOwnership) // `var x: T?`/`T!` is nil
                        continue
                    }
                    if !annotationText.isEmpty {
                        // Deferred initialization: `let x: T` assigned in
                        // branches — definite-init is the compiler's job.
                        env.define(
                            ident.identifier.text, .void,
                            declaredTypeName: annotationText,
                            referenceOwnership: referenceOwnership)
                        continue
                    }
                    throw error(binding, "'\(ident.identifier.text)' needs an initial value")
                }
                let hint = (binding.typeAnnotation?.type ?? sharedAnnotation(startingAt: bindingIndex))?
                    .trimmedDescription
                let value = try withExpectedAnnotation(hint) { try evaluate(initializer, in: env) }
                let resolved = try hint.map {
                    try resolveAnnotated(value, typeName: $0)
                } ?? value
                env.define(
                    ident.identifier.text, resolved,
                    declaredTypeName: hint,
                    referenceOwnership: referenceOwnership)
            }
            return
        }
        if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            try defineFunction(funcDecl, in: env)
            return
        }
        if decl.is(ImportDeclSyntax.self) {
            return // imports are module directives — no-ops in the merged model
        }
        if let alias = decl.as(TypeAliasDeclSyntax.self) {
            // Local `typealias Entity = NSEntityDescription` binds the name
            // to the target type in this scope (generic arguments dropped,
            // like everywhere else). Unknown host targets bind a type
            // marker; tuple/function aliases stay inert.
            var target = alias.initializer.value.trimmedDescription
            if let angle = target.firstIndex(of: "<") { target = String(target[..<angle]) }
            target = target.trimmingCharacters(in: .whitespaces)
            if let value = globals.lookup(target) ?? env.lookup(target) {
                env.define(alias.name.text, value)
            } else if let first = target.first, first.isUppercase, !target.contains("(") {
                env.define(alias.name.text, try resolveIdentifier(target, in: env, node: alias))
            }
            return
        }
        if decl.is(MacroDeclSyntax.self) {
            // `macro Reducer(…) = #externalMacro(…)` — a compile-time
            // construct; the runtime image holds no entity for it. USES are
            // separate: attached macros ride the attribute path, freestanding
            // expansions the MacroExpansionExpr path.
            return
        }
        // LOCAL type declarations (`struct FileCheck { … }` inside a
        // function — Danger scripts and helpers do this): collect the
        // symbol into the CURRENT scope; locals shadow globals.
        if let structDecl = decl.as(StructDeclSyntax.self) {
            let symbol = try makeStructSymbol(structDecl)
            env.define(symbol.name, .type(symbol))
            return
        }
        if let classDecl = decl.as(ClassDeclSyntax.self) {
            let symbol = try makeClassLikeSymbol(
                name: classDecl.name.text, inheritanceClause: classDecl.inheritanceClause,
                memberBlock: classDecl.memberBlock, attributes: classDecl.attributes)
            env.define(symbol.name, .type(symbol))
            return
        }
        if let enumDecl = decl.as(EnumDeclSyntax.self) {
            let symbol = try makeLocalEnumSymbol(enumDecl)
            env.define(symbol.name, .enumType(symbol))
            return
        }
        if decl.is(ExtensionDeclSyntax.self) {
            throw error(decl, "extensions must be declared at the top level")
        }
        throw error(decl, "unsupported declaration (\(decl.kind))")
    }

    /// `@Dependency(\.workspacePool) var pool` in statement position: the
    /// capitalized keypath component names the type; a collected type yields
    /// a fresh instance, anything else an absorbing marker.
    func localDependencyValue(
        _ varDecl: VariableDeclSyntax, in env: Environment
    ) throws -> RuntimeValue? {
        for attribute in varDecl.attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                  case .argumentList(let arguments)? = attr.arguments,
                  let keyPath = arguments.first?.expression.as(KeyPathExprSyntax.self),
                  let component = keyPath.components.last?.trimmedDescription
                      .split(separator: ".").last.map(String.init),
                  let first = component.first else { continue }
            let typeName = String(first).uppercased() + component.dropFirst()
            if let cached = dependencyCache[typeName] { return cached }
            if case .type(let symbol)? = globals.lookup(typeName),
               !dependencyInFlight.contains(typeName) {
                dependencyInFlight.insert(typeName)
                defer { dependencyInFlight.remove(typeName) }
                if let instance = try? instantiateRoot(symbol) {
                    dependencyCache[typeName] = instance
                    return instance
                }
            }
            return .implicitMember(typeName)
        }
        return nil
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
            // Return position carries the enclosing function's DECLARED
            // return type as the ambient hint (generic-return binding).
            let hint = enclosingReturnAnnotations.last.flatMap { $0 }
            let value = try withExpectedAnnotation(hint) {
                try returnStmt.expression.map { try evaluate($0, in: env) } ?? .void
            }
            return .returnValue(value)
        }
        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            return try executeGuard(guardStmt, in: env)
        }
        if let doStmt = stmt.as(DoStmtSyntax.self) {
            return try executeDo(doStmt, in: env)
        }
        if let throwStmt = stmt.as(ThrowStmtSyntax.self) {
            throw InterpretedThrow(value: try evaluate(throwStmt.expression, in: env))
        }
        if let forStmt = stmt.as(ForStmtSyntax.self) {
            return try executeFor(forStmt, in: env)
        }
        if let whileStmt = stmt.as(WhileStmtSyntax.self) {
            return try executeWhile(whileStmt, in: env)
        }
        if let repeatStmt = stmt.as(RepeatStmtSyntax.self) {
            return try executeRepeat(repeatStmt, in: env)
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
                // `if let _ = someOptional` — presence check, no binding.
                // (`_` arrives as a wildcard OR an expression pattern
                // wrapping the discard expression, depending on context.)
                let isDiscard = optionalBinding.pattern.is(WildcardPatternSyntax.self)
                    || optionalBinding.pattern.as(ExpressionPatternSyntax.self)?
                        .expression.is(DiscardAssignmentExprSyntax.self) == true
                if isDiscard {
                    guard let initializer = optionalBinding.initializer?.value else {
                        throw error(optionalBinding, "'let _' needs an initializer")
                    }
                    guard try evaluate(initializer, in: bindings)
                        .unwrappedOptionalOrSelf != nil else { return false }
                    continue
                }
                // `if let (a, b) = pair` — tuple destructuring. The pattern
                // arrives as a TuplePattern or an expression pattern wrapping
                // a tuple of unresolved names.
                var tupleNames: [String?]?
                if let tuplePattern = optionalBinding.pattern.as(TuplePatternSyntax.self) {
                    tupleNames = tuplePattern.elements.map {
                        $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    }
                } else if let exprPattern = optionalBinding.pattern.as(ExpressionPatternSyntax.self),
                          let tupleExpr = exprPattern.expression.as(TupleExprSyntax.self) {
                    tupleNames = tupleExpr.elements.map {
                        $0.expression.as(DeclReferenceExprSyntax.self)?.baseName.text
                            ?? $0.expression.as(PatternExprSyntax.self)?
                                .pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    }
                }
                if let names = tupleNames, let initializer = optionalBinding.initializer?.value {
                    let value = try evaluate(initializer, in: bindings)
                    guard let unwrapped = value.unwrappedOptionalOrSelf,
                          let tuple = unwrapped.tupleValue,
                          tuple.values.count == names.count else { return false }
                    for (name, elementValue) in zip(names, tuple.values) {
                        if let name { bindings.define(name, elementValue) }
                    }
                    continue
                }
                guard let ident = optionalBinding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw error(optionalBinding, "unsupported optional-binding pattern (\(optionalBinding.pattern.kind))")
                }
                let name = ident.identifier.text
                let value: RuntimeValue
                if let initializer = optionalBinding.initializer?.value {
                    value = try evaluate(initializer, in: bindings)
                } else {
                    // `if let x` shorthand
                    value = try resolveIdentifier(name, in: bindings, node: optionalBinding)
                }
                guard let unwrapped = value.unwrappedOptionalOrSelf else { return false }
                bindings.define(name, unwrapped)
            case .matchingPattern(let matching):
                // `if case .loading = state` — rides the switch matcher.
                let subject = try evaluate(matching.initializer.value, in: bindings)
                guard try matches(matching.pattern, subject: subject, bindingInto: bindings, env: bindings) else {
                    return false
                }
            case .availability:
                // Latest-SDK host: `#available(...)` checks pass.
                break
            default:
                throw error(element, "unsupported condition (\(element.condition))")
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

    /// `do`/`catch`: interpreted throws deliver their original value to the
    /// binding; non-fatal host errors arrive as their message (so real code's
    /// `catch { print(error) }` behaves sensibly for gateway failures too).
    private func executeDo(_ doStmt: DoStmtSyntax, in env: Environment) throws -> StatementResult {
        guard !doStmt.catchClauses.isEmpty else {
            return try executeBlock(doStmt.body.statements, in: Environment(parent: env))
        }
        do {
            return try executeBlock(doStmt.body.statements, in: Environment(parent: env))
        } catch is InterpreterSessionAbort {
            throw InterpreterSessionAbort()
        } catch let thrown as InterpretedThrow {
            return try executeCatch(doStmt.catchClauses, error: thrown.value, in: env)
        } catch let hostError as RuntimeError {
            if hostError.fatal { throw hostError }
            return try executeCatch(doStmt.catchClauses, error: .native(hostError.message), in: env)
        } catch {
            return try executeCatch(
                doStmt.catchClauses,
                error: .native(String(describing: error)),
                in: env)
        }
    }

    private func executeCatch(
        _ clauses: CatchClauseListSyntax,
        error thrown: RuntimeValue,
        in env: Environment
    ) throws -> StatementResult {
        // v1: the first clause handles everything; `catch let name` binds it.
        let clause = clauses.first!
        let child = Environment(parent: env)
        var name = "error"
        if let pattern = clause.catchItems.first?.pattern,
           let binding = pattern.as(ValueBindingPatternSyntax.self),
           let ident = binding.pattern.as(IdentifierPatternSyntax.self) {
            name = ident.identifier.text
        }
        child.define(name, thrown)
        return try executeBlock(clause.body.statements, in: child)
    }

    private func executeGuard(_ guardStmt: GuardStmtSyntax, in env: Environment) throws -> StatementResult {
        // Guard bindings live in the ENCLOSING scope on success.
        if try conditionsHold(guardStmt.conditions, in: env, bindingInto: env) {
            return .normal(.void)
        }
        let result = try executeBlock(guardStmt.body.statements, in: Environment(parent: env))
        if case .normal = result {
            // The compiler PROVED the else exits — a block that ran to
            // completion ended in an ABSORBED Never-return (`exit(1)` in
            // merged helper-tool files stays inert per the cStdlib
            // doctrine). The scope exits as the code intended.
            if Self.endsInCall(guardStmt.body.statements) {
                return .returnValue(.void)
            }
            throw error(guardStmt, "guard else must exit (return, break, or continue)")
        }
        return result
    }

    /// True when the block's last statement is a bare function call —
    /// compiled sources guarantee such a guard-else diverges (exit, abort,
    /// a Never-returning helper).
    static func endsInCall(_ statements: CodeBlockItemListSyntax) -> Bool {
        guard let last = statements.last else { return false }
        if case .expr(let expr) = last.item {
            return expr.is(FunctionCallExprSyntax.self)
        }
        if case .stmt(let stmt) = last.item,
           let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            return exprStmt.expression.is(FunctionCallExprSyntax.self)
        }
        return false
    }

    private func executeFor(_ forStmt: ForStmtSyntax, in env: Environment) throws -> StatementResult {
        let name: String?
        var tupleNames: [String?]?
        var casePattern: PatternSyntax?
        if let ident = forStmt.pattern.as(IdentifierPatternSyntax.self) {
            name = ident.identifier.text
        } else if forStmt.pattern.is(WildcardPatternSyntax.self) {
            name = nil // `for _ in …`
        } else if let tuplePattern = forStmt.pattern.as(TuplePatternSyntax.self) {
            // `for (index, digit) in text.enumerated()` — destructure tuples.
            name = nil
            tupleNames = tuplePattern.elements.map {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            }
        } else {
            // `for case let file as String in enumerator` and case-shaped
            // patterns: each element runs through the switch matcher;
            // non-matching elements skip.
            name = nil
            tupleNames = nil
            casePattern = forStmt.pattern
        }
        let sequence = try evaluate(forStmt.sequence, in: env)

        let elements: [RuntimeValue]
        if let range = sequence.rangeValue {
            guard let values = range.integerValues() else {
                throw error(forStmt.sequence, "for-in requires an integer range")
            }
            elements = values
        } else if let array = sequence.arrayValue {
            elements = array
        } else if let set = sequence.setValue {
            elements = set.elements
        } else if case .host(let any) = sequence,
                  any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            // Unknowable host collections (Activity<T>.activities on a fresh
            // device) iterate EMPTY — the fresh-store reading.
            elements = []
        } else if case .implicitMember = sequence {
            // Same doctrine: a bare `.member` in sequence position can only
            // be an unresolved host-static chain.
            elements = []
        } else if case .hostFunction = sequence {
            // A bound host member in sequence position (stub.allKeys) is
            // equally unknowable — real code can't iterate a function.
            elements = []
        } else if case .host(let dataAny) = sequence, let bytes = dataAny as? Data {
            elements = bytes.map { .native(Int($0)) } // byte collection
        } else if let dict = sequence.dictValue {
            // `for (id, count) in sales` — native Dictionary iteration
            // yields (key, value) tuples, in the dict's stable order.
            elements = zip(dict.keys, dict.values).map { key, value in
                .native(TupleValue(labels: ["key", "value"], values: [key, value]))
            }
        } else {
            throw error(forStmt.sequence, "for-in requires a range or an array, got \(sequence.stringified)")
        }

        let preparedLoop: PreparedFiniteLoop?
        if casePattern == nil, tupleNames == nil {
            preparedLoop = prepareFiniteIntegerLoop(
                body: forStmt.body.statements,
                loopVariableName: name,
                parent: env,
                elements: elements)
        } else {
            preparedLoop = nil
        }

        if let preparedLoop {
            return try preparedLoop.execute(interpreter: self)
        }

        loop: for element in elements {
            try checkRuntimeCancellation()

            let child = Environment(parent: env)
            if let casePattern {
                guard try matches(casePattern, subject: element, bindingInto: child, env: env) else {
                    continue
                }
            }
            if let name { child.define(name, element) }
            if let tupleNames {
                guard let tuple = element.tupleValue, tuple.values.count == tupleNames.count else {
                    throw error(forStmt.pattern, "for-in tuple pattern doesn't match the element shape")
                }
                for (elementName, value) in zip(tupleNames, tuple.values) {
                    if let elementName { child.define(elementName, value) }
                }
            }
            let result = try withFiniteIterationSlice {
                try executeBlock(forStmt.body.statements, in: child)
            }
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

    /// `repeat { body } while cond` — the body runs once BEFORE the condition
    /// is first evaluated. The trailing condition is a plain expression (no
    /// optional binding), evaluated in the enclosing scope: variables declared
    /// inside the body are not visible to it. `continue` falls through to the
    /// condition check, exactly as native `repeat`/`while` does.
    private func executeRepeat(_ repeatStmt: RepeatStmtSyntax, in env: Environment) throws -> StatementResult {
        while true {
            try tick(repeatStmt)
            let child = Environment(parent: env)
            let result = try executeBlock(repeatStmt.body.statements, in: child)
            switch result {
            case .normal, .continueLoop: break
            case .breakLoop: return .normal(.void)
            case .returnValue: return result
            }
            guard try evaluate(repeatStmt.condition, in: env).boolValue == true else { break }
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
                if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                    // `#if os(iOS)` in builder position: the active clause's
                    // items contribute their views.
                    if let clause = activeIfConfigClause(ifConfig),
                       case .statements(let activeItems)? = clause.elements {
                        views += try collectBuilderViews(activeItems, in: env)
                    }
                    continue
                }
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
                if stmt.is(DoStmtSyntax.self) || stmt.is(GuardStmtSyntax.self)
                    || stmt.is(ForStmtSyntax.self) || stmt.is(WhileStmtSyntax.self)
                    || stmt.is(BreakStmtSyntax.self) || stmt.is(ContinueStmtSyntax.self) {
                    // Imperative statements inside builder-evaluated closures
                    // (`.task { do { try await fetch() } catch {} }`) execute
                    // for effect; an explicit return contributes its view.
                    let result = try executeStatement(stmt, in: env)
                    if case .returnValue(let value) = result {
                        appendViewValue(value, to: &views)
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
        case .nilValue:
            // Optional views render nothing when nil — ViewBuilder's
            // buildExpression(Optional) (`randomIsland.map { … }`).
            break
        case .optional(let optional):
            if let wrapped = optional.wrapped {
                appendViewValue(wrapped, to: &views)
            }
        case .instance(let instance) where instance.symbol.rendersLikeView:
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
