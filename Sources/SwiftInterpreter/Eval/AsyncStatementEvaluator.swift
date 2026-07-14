import Foundation
import SwiftSyntax

private struct AsyncLetProjectedBinding {
    let name: String
    let tupleProjection: [Int]
    let annotation: String?
}

extension Interpreter {
    // MARK: - Suspension-aware statements

    func executeBlockSuspending(
        _ items: CodeBlockItemListSyntax, in env: Environment
    ) async throws -> StatementResult {
        let structuredScope = RuntimeStructuredScopeFrame(
            ownerTaskID: evaluationTaskContext.runtimeTaskID)
        evaluationTaskContext.structuredScopeFrames.append(structuredScope)
        defer {
            precondition(
                evaluationTaskContext.structuredScopeFrames.last
                    .map { $0 === structuredScope } == true,
                "structured scope frames must unwind in lexical order")
            evaluationTaskContext.structuredScopeFrames.removeLast()
        }

        var last: RuntimeValue = .void
        var deferredBodies: [CodeBlockItemListSyntax] = []

        do {
            for item in items {
                try checkRuntimeCancellation()
                if case .stmt(let statement) = item.item,
                   let deferStatement = statement.as(DeferStmtSyntax.self) {
                    let slot = deferredBodies.count
                    deferredBodies.append(deferStatement.body.statements)
                    structuredScope.cleanups.append(.deferredBody(slot))
                    continue
                }
                let result = try await executeSuspending(item, in: env)
                guard case .normal(let value) = result else {
                    await closeStructuredScope(
                        structuredScope,
                        deferredBodies: deferredBodies,
                        in: env)
                    return result
                }
                last = value
            }
        } catch {
            await closeStructuredScope(
                structuredScope,
                deferredBodies: deferredBodies,
                in: env)
            throw error
        }
        await closeStructuredScope(
            structuredScope,
            deferredBodies: deferredBodies,
            in: env)
        return .normal(last)
    }

    private func closeStructuredScope(
        _ frame: RuntimeStructuredScopeFrame,
        deferredBodies: [CodeBlockItemListSyntax],
        in env: Environment
    ) async {
        for cleanup in frame.cleanups.reversed() {
            switch cleanup {
            case .deferredBody(let slot):
                precondition(
                    deferredBodies.indices.contains(slot),
                    "deferred cleanup refers to an unknown body")
                _ = try? await executeBlockSuspending(
                    deferredBodies[slot], in: env)
            case .asyncLet(let group):
                // Bindings from one declaration form one cleanup. Cancel all
                // first so joining an earlier child cannot delay a sibling's
                // cancellation, then join the entire group before unwinding
                // the next outer lexical cleanup.
                for child in group.children {
                    child.cancelIfUnconsumedAtScopeExit()
                }
                for child in group.children {
                    await child.waitForScopeExit(waiter: frame.ownerTaskID)
                }
            }
        }
        if let runtimeScope = frame.runtimeScope {
            concurrencyRuntime.closeStructuredScope(runtimeScope)
        }
        for cleanup in frame.cleanups {
            guard case .asyncLet(let group) = cleanup else { continue }
            for child in group.children {
                concurrencyRuntime.release(child.handle.id)
            }
        }
        frame.cleanups.removeAll(keepingCapacity: false)
        frame.runtimeScope = nil
    }

    func executeSuspending(
        _ item: CodeBlockItemSyntax, in env: Environment
    ) async throws -> StatementResult {
        try checkRuntimeCancellation()
        try tick(item)
        switch item.item {
        case .decl(let declaration):
            if let ifConfig = declaration.as(IfConfigDeclSyntax.self) {
                if let clause = activeIfConfigClause(ifConfig),
                   case .statements(let active)? = clause.elements {
                    return try await executeBlockSuspending(active, in: env)
                }
                return .normal(.void)
            }
            try await executeDeclSuspending(declaration, in: env)
            return .normal(.void)

        case .stmt(let statement):
            return try await executeStatementSuspending(statement, in: env)

        case .expr(let expression):
            if let ifExpression = expression.as(IfExprSyntax.self) {
                return try await executeIfSuspending(ifExpression, in: env)
            }
            if let switchExpression = expression.as(SwitchExprSyntax.self) {
                return try await executeSwitchSuspending(switchExpression, in: env)
            }
            if let macro = expression.as(MacroExpansionExprSyntax.self) {
                _ = try invokeRegisteredMacro(
                    named: macro.macroName.text,
                    arguments: macro.arguments,
                    trailingClosure: macro.trailingClosure,
                    additionalTrailingClosures: macro.additionalTrailingClosures,
                    node: macro,
                    in: env)
                return .normal(.void)
            }
            return .normal(try await evaluateSuspending(expression, in: env))
        }
    }

    func executeDeclSuspending(
        _ declaration: DeclSyntax, in env: Environment
    ) async throws {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            try executeDecl(declaration, in: env)
            return
        }

        let bindings = Array(variable.bindings)
        func sharedAnnotation(startingAt index: Int) -> TypeSyntax? {
            for later in bindings[index...] {
                if let type = later.typeAnnotation?.type { return type }
                if later.initializer != nil { return nil }
            }
            return nil
        }

        if variable.modifiers.contains(where: { $0.name.text == "async" }) {
            try executeAsyncLetDeclaration(
                variable, bindings: bindings, in: env)
            return
        }

        for (index, binding) in bindings.enumerated() {
            if binding.pattern.is(WildcardPatternSyntax.self) {
                if let initializer = binding.initializer?.value {
                    _ = try await evaluateSuspending(initializer, in: env)
                }
                continue
            }

            if let tuplePattern = binding.pattern.as(TuplePatternSyntax.self),
               let initializer = binding.initializer?.value {
                let value = try await evaluateSuspending(initializer, in: env)
                guard let tuple = value.tupleValue,
                      tuple.values.count == tuplePattern.elements.count else {
                    throw error(binding, "tuple binding doesn't match the value shape")
                }
                for (element, elementValue) in zip(tuplePattern.elements, tuple.values) {
                    if let identifier = element.pattern.as(IdentifierPatternSyntax.self) {
                        env.define(identifier.identifier.text, elementValue)
                    }
                }
                continue
            }

            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                throw error(binding, "unsupported binding pattern")
            }
            let name = identifier.identifier.text

            if let accessorBlock = binding.accessorBlock {
                guard let accessors = parseAccessors(of: accessorBlock) else {
                    throw error(binding, "unsupported accessor block on local binding")
                }
                let result = try await executeBlockSuspending(
                    accessors.getter, in: Environment(parent: env))
                switch result {
                case .normal(let value), .returnValue(let value):
                    let typeName = binding.typeAnnotation?.type.trimmedDescription
                    env.define(name, try resolveAnnotated(
                        value, annotation: binding.typeAnnotation?.type),
                        declaredTypeName: typeName)
                default:
                    throw error(binding, "control flow escaped local computed var")
                }
                continue
            }

            guard let initializer = binding.initializer?.value else {
                if let injected = try localDependencyValue(variable, in: env) {
                    env.define(name, injected)
                    continue
                }
                let annotation = (binding.typeAnnotation?.type
                    ?? sharedAnnotation(startingAt: index))?.trimmedDescription ?? ""
                if RuntimeOptionalValue.wrappedType(in: annotation) != nil {
                    env.define(
                        name, .none(forTypeAnnotation: annotation),
                        declaredTypeName: annotation)
                } else if !annotation.isEmpty {
                    env.define(name, .void, declaredTypeName: annotation)
                } else {
                    throw error(binding, "'\(name)' needs an initial value")
                }
                continue
            }

            let hint = (binding.typeAnnotation?.type
                ?? sharedAnnotation(startingAt: index))?.trimmedDescription
            let value = try await withExpectedAnnotationSuspending(hint) {
                try await evaluateSuspending(initializer, in: env)
            }
            let resolved = try hint.map {
                try resolveAnnotated(value, typeName: $0)
            } ?? value
            env.define(name, resolved, declaredTypeName: hint)
        }
    }

    private func executeAsyncLetDeclaration(
        _ variable: VariableDeclSyntax,
        bindings: [PatternBindingSyntax],
        in env: Environment
    ) throws {
        guard variable.bindingSpecifier.text == "let" else {
            throw error(variable, "async bindings must use let")
        }
        guard evaluationTaskContext.isAsyncSession,
              let ownerTaskID = evaluationTaskContext.runtimeTaskID else {
            throw error(variable, "async let requires runAsync")
        }
        guard let frame = evaluationTaskContext.structuredScopeFrames.last,
              frame.ownerTaskID == ownerTaskID else {
            throw error(variable,
                "async let requires an active structured scope")
        }

        let runtimeScope: RuntimeStructuredScopeRecord
        if let existing = frame.runtimeScope {
            runtimeScope = existing
        } else {
            runtimeScope = concurrencyRuntime.createStructuredScope(
                ownerTaskID: ownerTaskID)
            frame.runtimeScope = runtimeScope
        }

        func sharedAnnotation(startingAt index: Int) -> TypeSyntax? {
            for later in bindings[index...] {
                if let type = later.typeAnnotation?.type { return type }
                if later.initializer != nil { return nil }
            }
            return nil
        }

        let cleanupGroup = RuntimeAsyncLetCleanupGroup()
        frame.cleanups.append(.asyncLet(cleanupGroup))
        for (index, binding) in bindings.enumerated() {
            guard binding.accessorBlock == nil,
                  let initializer = binding.initializer?.value else {
                throw error(binding,
                    "async let '\(binding.pattern.trimmedDescription)' needs an initializer")
            }
            let annotationSyntax = binding.typeAnnotation?.type
                ?? sharedAnnotation(startingAt: index)
            let projectedBindings = try asyncLetProjectedBindings(
                for: binding.pattern,
                annotation: annotationSyntax,
                tupleProjection: [])
            let annotation = annotationSyntax?.trimmedDescription
            let handle = try spawnAsyncLetTask(
                initializer: initializer,
                in: env,
                annotation: annotation)
            let child = RuntimeAsyncLetChild(handle: handle)
            concurrencyRuntime.addStructuredChild(
                handle.id, to: runtimeScope)
            cleanupGroup.children.append(child)
            for projected in projectedBindings {
                let asyncBinding = RuntimeAsyncLetBinding(
                    name: projected.name,
                    child: child,
                    tupleProjection: projected.tupleProjection)
                env.define(
                    projected.name,
                    .native(asyncBinding),
                    declaredTypeName: projected.annotation)
            }
        }
    }

    private func asyncLetProjectedBindings(
        for pattern: PatternSyntax,
        annotation: TypeSyntax?,
        tupleProjection: [Int]
    ) throws -> [AsyncLetProjectedBinding] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return [AsyncLetProjectedBinding(
                name: identifier.identifier.text,
                tupleProjection: tupleProjection,
                annotation: annotation?.trimmedDescription)]
        }
        if pattern.is(WildcardPatternSyntax.self) { return [] }
        if let tuplePattern = pattern.as(TuplePatternSyntax.self) {
            let elements = Array(tuplePattern.elements)
            let annotations: [TypeSyntax?]
            if let tupleType = annotation?.as(TupleTypeSyntax.self),
               tupleType.elements.count == elements.count {
                annotations = tupleType.elements.map { $0.type }
            } else {
                annotations = Array(repeating: nil, count: elements.count)
            }
            var result: [AsyncLetProjectedBinding] = []
            for (index, element) in elements.enumerated() {
                result += try asyncLetProjectedBindings(
                    for: element.pattern,
                    annotation: annotations[index],
                    tupleProjection: tupleProjection + [index])
            }
            return result
        }
        throw error(pattern, "unsupported async-let binding pattern")
    }

    func evaluateAsyncLetInitializerSuspending(
        _ initializer: ExprSyntax,
        in env: Environment,
        annotation: String?
    ) async throws -> RuntimeValue {
        let value = try await withExpectedAnnotationSuspending(annotation) {
            // Unlike an ordinary let initializer, async-let initialization
            // has an implicit suspension boundary even when the source call
            // is not spelled with `await`.
            try await evaluateSuspending(
                initializer, in: env, forceInvocation: true)
        }
        guard let annotation else { return value }
        return try resolveAnnotated(value, typeName: annotation)
    }

    private func executeStatementSuspending(
        _ statement: StmtSyntax, in env: Environment
    ) async throws -> StatementResult {
        if let expressionStatement = statement.as(ExpressionStmtSyntax.self) {
            if let ifExpression = expressionStatement.expression.as(IfExprSyntax.self) {
                return try await executeIfSuspending(ifExpression, in: env)
            }
            if let switchExpression = expressionStatement.expression.as(SwitchExprSyntax.self) {
                return try await executeSwitchSuspending(switchExpression, in: env)
            }
            return .normal(try await evaluateSuspending(
                expressionStatement.expression, in: env))
        }

        if let returnStatement = statement.as(ReturnStmtSyntax.self) {
            let hint = enclosingReturnAnnotations.last.flatMap { $0 }
            let value = try await withExpectedAnnotationSuspending(hint) {
                if let expression = returnStatement.expression {
                    return try await evaluateSuspending(expression, in: env)
                }
                return RuntimeValue.void
            }
            return .returnValue(value)
        }

        if let guardStatement = statement.as(GuardStmtSyntax.self) {
            return try await executeGuardSuspending(guardStatement, in: env)
        }
        if let doStatement = statement.as(DoStmtSyntax.self) {
            return try await executeDoSuspending(doStatement, in: env)
        }
        if let throwStatement = statement.as(ThrowStmtSyntax.self) {
            throw InterpretedThrow(value: try await evaluateSuspending(
                throwStatement.expression, in: env))
        }
        if let forStatement = statement.as(ForStmtSyntax.self) {
            return try await executeForSuspending(forStatement, in: env)
        }
        if let whileStatement = statement.as(WhileStmtSyntax.self) {
            return try await executeWhileSuspending(whileStatement, in: env)
        }
        if statement.is(BreakStmtSyntax.self) { return .breakLoop }
        if statement.is(ContinueStmtSyntax.self) { return .continueLoop }
        throw error(statement, "unsupported statement (\(statement.kind))")
    }

    // MARK: Conditions and branches

    func conditionsHoldSuspending(
        _ conditions: ConditionElementListSyntax,
        in env: Environment,
        bindingInto bindings: Environment
    ) async throws -> Bool {
        for element in conditions {
            try checkRuntimeCancellation()
            switch element.condition {
            case .expression(let condition):
                guard try expectBool(
                    await evaluateSuspending(condition, in: bindings),
                    node: condition) else { return false }

            case .optionalBinding(let optionalBinding):
                let isDiscard = optionalBinding.pattern.is(WildcardPatternSyntax.self)
                    || optionalBinding.pattern.as(ExpressionPatternSyntax.self)?
                        .expression.is(DiscardAssignmentExprSyntax.self) == true
                if isDiscard {
                    guard let initializer = optionalBinding.initializer?.value else {
                        throw error(optionalBinding, "'let _' needs an initializer")
                    }
                    let value = try await evaluateSuspending(initializer, in: bindings)
                    guard value.unwrappedOptionalOrSelf != nil else { return false }
                    continue
                }

                var tupleNames: [String?]?
                if let tuple = optionalBinding.pattern.as(TuplePatternSyntax.self) {
                    tupleNames = tuple.elements.map {
                        $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    }
                } else if let expressionPattern = optionalBinding.pattern
                    .as(ExpressionPatternSyntax.self),
                    let tuple = expressionPattern.expression.as(TupleExprSyntax.self) {
                    tupleNames = tuple.elements.map {
                        $0.expression.as(DeclReferenceExprSyntax.self)?.baseName.text
                            ?? $0.expression.as(PatternExprSyntax.self)?
                                .pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                    }
                }
                if let names = tupleNames,
                   let initializer = optionalBinding.initializer?.value {
                    let value = try await evaluateSuspending(initializer, in: bindings)
                    guard let unwrapped = value.unwrappedOptionalOrSelf,
                          let tuple = unwrapped.tupleValue,
                          tuple.values.count == names.count else { return false }
                    for (name, elementValue) in zip(names, tuple.values) {
                        if let name { bindings.define(name, elementValue) }
                    }
                    continue
                }

                guard let identifier = optionalBinding.pattern
                    .as(IdentifierPatternSyntax.self) else {
                    throw error(optionalBinding, "unsupported optional-binding pattern")
                }
                let name = identifier.identifier.text
                let value: RuntimeValue
                if let initializer = optionalBinding.initializer?.value {
                    value = try await evaluateSuspending(initializer, in: bindings)
                } else {
                    value = try resolveIdentifier(name, in: bindings, node: optionalBinding)
                }
                guard let unwrapped = value.unwrappedOptionalOrSelf else { return false }
                bindings.define(name, unwrapped)

            case .matchingPattern(let matching):
                let subject = try await evaluateSuspending(
                    matching.initializer.value, in: bindings)
                guard try matches(
                    matching.pattern, subject: subject,
                    bindingInto: bindings, env: bindings) else { return false }

            case .availability:
                break
            }
        }
        return true
    }

    func executeIfSuspending(
        _ ifExpression: IfExprSyntax, in env: Environment
    ) async throws -> StatementResult {
        let child = Environment(parent: env)
        if try await conditionsHoldSuspending(
            ifExpression.conditions, in: env, bindingInto: child) {
            return try await executeBlockSuspending(
                ifExpression.body.statements, in: child)
        }
        switch ifExpression.elseBody {
        case .none:
            return .normal(.void)
        case .codeBlock(let block):
            return try await executeBlockSuspending(
                block.statements, in: Environment(parent: env))
        case .ifExpr(let nested):
            return try await executeIfSuspending(nested, in: env)
        }
    }

    private func executeGuardSuspending(
        _ guardStatement: GuardStmtSyntax, in env: Environment
    ) async throws -> StatementResult {
        if try await conditionsHoldSuspending(
            guardStatement.conditions, in: env, bindingInto: env) {
            return .normal(.void)
        }
        let result = try await executeBlockSuspending(
            guardStatement.body.statements, in: Environment(parent: env))
        if case .normal = result {
            if Self.endsInCall(guardStatement.body.statements) {
                return .returnValue(.void)
            }
            throw error(guardStatement, "guard else must exit (return, break, or continue)")
        }
        return result
    }

    private func executeDoSuspending(
        _ doStatement: DoStmtSyntax, in env: Environment
    ) async throws -> StatementResult {
        guard !doStatement.catchClauses.isEmpty else {
            return try await executeBlockSuspending(
                doStatement.body.statements, in: Environment(parent: env))
        }
        do {
            return try await executeBlockSuspending(
                doStatement.body.statements, in: Environment(parent: env))
        } catch is InterpreterSessionAbort {
            throw InterpreterSessionAbort()
        } catch is CancellationError {
            // Classify infrastructure teardown before recording a source
            // observation. A root/host or session-policy abort must bypass
            // source catch clauses without acquiring a spurious `.inherited`
            // cancellation source. Ordinary task cancellation remains
            // cooperative and reaches the catch path below.
            try checkRuntimeCancellation()
            observeSourceCancellation()
            return try await executeCatchSuspending(
                doStatement.catchClauses,
                error: .native(CancellationError()),
                in: env)
        } catch let thrown as InterpretedThrow {
            return try await executeCatchSuspending(
                doStatement.catchClauses, error: thrown.value, in: env)
        } catch let hostError as RuntimeError where !hostError.fatal {
            return try await executeCatchSuspending(
                doStatement.catchClauses,
                error: .native(hostError.message),
                in: env)
        } catch {
            return try await executeCatchSuspending(
                doStatement.catchClauses,
                error: .native(String(describing: error)),
                in: env)
        }
    }

    private func executeCatchSuspending(
        _ clauses: CatchClauseListSyntax,
        error thrown: RuntimeValue,
        in env: Environment
    ) async throws -> StatementResult {
        let clause = clauses.first!
        let child = Environment(parent: env)
        var name = "error"
        if let pattern = clause.catchItems.first?.pattern,
           let binding = pattern.as(ValueBindingPatternSyntax.self),
           let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
            name = identifier.identifier.text
        }
        child.define(name, thrown)
        return try await executeBlockSuspending(clause.body.statements, in: child)
    }

    // MARK: Switch

    func executeSwitchSuspending(
        _ switchExpression: SwitchExprSyntax, in env: Environment
    ) async throws -> StatementResult {
        var selected = try await selectCaseSuspending(switchExpression, in: env)
        while true {
            let falls = Self.trailingFallthrough(selected.statements)
            let body = falls
                ? CodeBlockItemListSyntax(Array(selected.statements.dropLast()))
                : selected.statements
            let result = try await executeBlockSuspending(body, in: selected.env)
            if case .breakLoop = result { return .normal(.void) }
            if falls, case .normal = result,
               let next = caseStatements(
                   after: selected.caseIndex, in: switchExpression) {
                selected = (next.index, next.statements, Environment(parent: env))
                continue
            }
            return result
        }
    }

    private func selectCaseSuspending(
        _ switchExpression: SwitchExprSyntax, in env: Environment
    ) async throws -> (
        caseIndex: Int, statements: CodeBlockItemListSyntax, env: Environment
    ) {
        let subject = try await evaluateSuspending(switchExpression.subject, in: env)
        var defaultCase: (Int, CodeBlockItemListSyntax)?
        let cases = flattenedSwitchCases(switchExpression)

        for (index, switchCase) in cases.enumerated() {
            switch switchCase.label {
            case .default:
                defaultCase = (index, switchCase.statements)
            case .case(let label):
                for item in label.caseItems {
                    let child = Environment(parent: env)
                    guard try matches(
                        item.pattern, subject: subject,
                        bindingInto: child, env: env) else { continue }
                    if let whereClause = item.whereClause {
                        guard try expectBool(
                            await evaluateSuspending(whereClause.condition, in: child),
                            node: whereClause.condition) else { continue }
                    }
                    return (index, switchCase.statements, child)
                }
            }
        }
        if let (index, statements) = defaultCase {
            return (index, statements, Environment(parent: env))
        }
        if isUnknowable(subject) {
            for (index, switchCase) in cases.enumerated() {
                guard case .case(let label) = switchCase.label,
                      let item = label.caseItems.first else { continue }
                let child = Environment(parent: env)
                bindPatternsToUnknowables(item.pattern, into: child)
                return (index, switchCase.statements, child)
            }
        }
        throw error(
            switchExpression,
            "switch was not exhaustive for \(subject.stringified)")
    }

    // MARK: Loops

    private func executeForSuspending(
        _ forStatement: ForStmtSyntax, in env: Environment
    ) async throws -> StatementResult {
        let name: String?
        var tupleNames: [String?]?
        var casePattern: PatternSyntax?
        if let identifier = forStatement.pattern.as(IdentifierPatternSyntax.self) {
            name = identifier.identifier.text
        } else if forStatement.pattern.is(WildcardPatternSyntax.self) {
            name = nil
        } else if let tuple = forStatement.pattern.as(TuplePatternSyntax.self) {
            name = nil
            tupleNames = tuple.elements.map {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            }
        } else {
            name = nil
            tupleNames = nil
            casePattern = forStatement.pattern
        }

        let sequence = try await evaluateSuspending(forStatement.sequence, in: env)
        let elements: [RuntimeValue]
        if let range = sequence.rangeValue {
            guard let values = range.integerValues() else {
                throw error(forStatement.sequence, "for-in requires an integer range")
            }
            elements = values
        } else if let array = sequence.arrayValue {
            elements = array
        } else if let set = sequence.setValue {
            elements = set.elements
        } else if case .host(let any) = sequence,
                  any is InertCallable || any is ChainedImplicitCall
                    || any is ImplicitMemberCall {
            elements = []
        } else if case .implicitMember = sequence {
            elements = []
        } else if case .hostFunction = sequence {
            elements = []
        } else if case .host(let any) = sequence, let bytes = any as? Data {
            elements = bytes.map { .native(Int($0)) }
        } else if let dictionary = sequence.dictValue {
            elements = zip(dictionary.keys, dictionary.values).map { key, value in
                .native(TupleValue(
                    labels: ["key", "value"], values: [key, value]))
            }
        } else {
            throw error(
                forStatement.sequence,
                "for-in requires a range or an array, got \(sequence.stringified)")
        }

        let preparedLoop: PreparedFiniteLoop?
        if casePattern == nil, tupleNames == nil {
            preparedLoop = prepareFiniteIntegerLoop(
                body: forStatement.body.statements,
                loopVariableName: name,
                parent: env,
                elements: elements)
        } else {
            preparedLoop = nil
        }

        if let preparedLoop {
            return try await preparedLoop.executeSuspending(interpreter: self)
        }

        loop: for element in elements {
            try checkRuntimeCancellation()

            let child = Environment(parent: env)
            if let casePattern {
                guard try matches(
                    casePattern, subject: element,
                    bindingInto: child, env: env) else { continue }
            }
            if let name { child.define(name, element) }
            if let tupleNames {
                guard let tuple = element.tupleValue,
                      tuple.values.count == tupleNames.count else {
                    throw error(
                        forStatement.pattern,
                        "for-in tuple pattern doesn't match the element shape")
                }
                for (elementName, value) in zip(tupleNames, tuple.values) {
                    if let elementName { child.define(elementName, value) }
                }
            }
            let result = try await withFiniteIterationSlice {
                try await executeBlockSuspending(
                    forStatement.body.statements, in: child)
            }
            switch result {
            case .normal, .continueLoop:
                continue
            case .breakLoop:
                break loop
            case .returnValue:
                return result
            }
        }
        return .normal(.void)
    }

    private func executeWhileSuspending(
        _ whileStatement: WhileStmtSyntax, in env: Environment
    ) async throws -> StatementResult {
        while true {
            try checkRuntimeCancellation()
            try tick(whileStatement)
            let child = Environment(parent: env)
            guard try await conditionsHoldSuspending(
                whileStatement.conditions, in: env,
                bindingInto: child) else { break }
            let result = try await executeBlockSuspending(
                whileStatement.body.statements, in: child)
            switch result {
            case .normal, .continueLoop:
                continue
            case .breakLoop:
                return .normal(.void)
            case .returnValue:
                return result
            }
        }
        return .normal(.void)
    }
}
