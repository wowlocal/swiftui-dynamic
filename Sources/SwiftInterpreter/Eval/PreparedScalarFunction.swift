import Foundation
import SwiftSyntax

/// Cached eligibility for the compact scalar-function evaluator. Declaration
/// identity is only the cache key; admission is structural and type-based.
@MainActor
enum PreparedScalarFunctionCache {
    case unavailable
    case prepared(PreparedScalarFunction)
}

/// A compact plan for straight-line fixed-width scalar helpers.
///
/// Source packages commonly factor bit tests and numeric predicates into tiny
/// functions called inside scans. Re-walking the same SwiftSyntax tree for
/// every element can dominate the actual operation. This plan admits only
/// scalar parameters/receivers, local scalar initializers, immutable reads of
/// stored `Self` statics, and one return expression. Unsupported syntax falls
/// back to the ordinary evaluator, so this is an execution optimization rather
/// than a second language surface.
@MainActor
final class PreparedScalarFunction {
    private struct RuntimeFallback: Error {}

    private enum StaticOwner {
        case structure(StructSymbol)
        case enumeration(EnumSymbol)
    }

    private struct ScalarSwitchCase {
        let patterns: [Expression]?
        let result: Expression
    }

    private indirect enum Expression {
        case slot(Int)
        case receiver
        case constant(RuntimeValue)
        case instanceMember(String, ExprSyntax)
        case staticMember(StaticOwner, String, ExprSyntax)
        case integerSubscript(Expression, Expression, SubscriptCallExprSyntax)
        case scalarSwitch(Expression, [ScalarSwitchCase], SwitchExprSyntax)
        case binary(String, Expression, Expression, ExprSyntax)
        case prefix(String, Expression, ExprSyntax)

        @MainActor
        func evaluate(
            slots: [RuntimeValue], receiver: RuntimeValue?,
            interpreter: Interpreter
        ) throws -> RuntimeValue {
            switch self {
            case .slot(let index):
                return slots[index]
            case .receiver:
                guard let receiver,
                      PreparedScalarFunction.isFixedWidthScalar(receiver) else {
                    throw RuntimeFallback()
                }
                return receiver
            case .constant(let value):
                return value
            case .instanceMember(let name, _):
                guard case .instance(let instance)? = receiver,
                      let box = instance.box(for: name) else {
                    throw RuntimeFallback()
                }
                try interpreter.requireActorStoredPropertyAccess(
                    instance, property: name)
                let value = try box.load()
                guard PreparedScalarFunction.isFixedWidthScalar(value) else {
                    throw RuntimeFallback()
                }
                return value
            case .staticMember(let owner, let name, let node):
                let value: RuntimeValue?
                switch owner {
                case .structure(let symbol):
                    value = try interpreter.staticMember(name, of: symbol)
                case .enumeration(let symbol):
                    value = try interpreter.staticMember(name, of: symbol)
                }
                guard let value else {
                    throw interpreter.error(
                        node, "stored scalar static '\(name)' is unavailable")
                }
                return value
            case .integerSubscript(let base, let index, let node):
                let collection = try base.evaluate(
                    slots: slots, receiver: receiver,
                    interpreter: interpreter)
                let indexValue = try index.evaluate(
                    slots: slots, receiver: receiver,
                    interpreter: interpreter)
                guard let position = indexValue.intValue else {
                    throw RuntimeFallback()
                }
                if case .host(let payload) = collection,
                   let readable = payload as?
                    any RuntimeIntegerSubscriptReadable {
                    do {
                        return try readable.runtimeElement(at: position)
                    } catch let message as EvalMessage {
                        throw interpreter.error(node, message.text)
                    }
                }
                if let values = collection.arrayValue,
                   values.indices.contains(position) {
                    return values[position]
                }
                throw RuntimeFallback()
            case .scalarSwitch(let subject, let cases, let node):
                let value = try subject.evaluate(
                    slots: slots, receiver: receiver,
                    interpreter: interpreter)
                var fallback: Expression?
                for branch in cases {
                    guard let patterns = branch.patterns else {
                        fallback = branch.result
                        continue
                    }
                    for pattern in patterns {
                        let candidate = try pattern.evaluate(
                            slots: slots, receiver: receiver,
                            interpreter: interpreter)
                        do {
                            if try Builtins.binary("==", value, candidate)
                                .boolValue == true {
                                return try branch.result.evaluate(
                                    slots: slots, receiver: receiver,
                                    interpreter: interpreter)
                            }
                        } catch let message as EvalMessage {
                            throw interpreter.error(node, message.text)
                        }
                    }
                }
                guard let fallback else { throw RuntimeFallback() }
                return try fallback.evaluate(
                    slots: slots, receiver: receiver,
                    interpreter: interpreter)
            case .binary(let operation, let lhs, let rhs, let node):
                if operation == "&&" {
                    let left = try lhs.evaluate(
                        slots: slots, receiver: receiver,
                        interpreter: interpreter)
                    guard left.boolValue == true else { return .native(false) }
                    return try rhs.evaluate(
                        slots: slots, receiver: receiver,
                        interpreter: interpreter)
                }
                if operation == "||" {
                    let left = try lhs.evaluate(
                        slots: slots, receiver: receiver,
                        interpreter: interpreter)
                    guard left.boolValue != true else { return .native(true) }
                    return try rhs.evaluate(
                        slots: slots, receiver: receiver,
                        interpreter: interpreter)
                }
                do {
                    return try Builtins.binary(
                        operation,
                        lhs.evaluate(
                            slots: slots, receiver: receiver,
                            interpreter: interpreter),
                        rhs.evaluate(
                            slots: slots, receiver: receiver,
                            interpreter: interpreter))
                } catch let message as EvalMessage {
                    throw interpreter.error(node, message.text)
                }
            case .prefix(let operation, let operand, let node):
                do {
                    return try Builtins.prefix(
                        operation,
                        operand.evaluate(
                            slots: slots, receiver: receiver,
                            interpreter: interpreter))
                } catch let message as EvalMessage {
                    throw interpreter.error(node, message.text)
                }
            }
        }
    }

    private struct Initializer {
        let slot: Int
        let expression: Expression
    }

    private struct EarlyReturn {
        let condition: Expression
        let value: Expression
    }

    private let slotNames: [String]
    private let parameterCount: Int
    private let earlyReturns: [EarlyReturn]
    private let initializers: [Initializer]
    private let result: Expression

    private init(
        slotNames: [String], parameterCount: Int,
        earlyReturns: [EarlyReturn], initializers: [Initializer],
        result: Expression
    ) {
        self.slotNames = slotNames
        self.parameterCount = parameterCount
        self.earlyReturns = earlyReturns
        self.initializers = initializers
        self.result = result
    }

    func execute(
        arguments: [RuntimeValue], receiver: RuntimeValue?,
        interpreter: Interpreter
    ) throws -> RuntimeValue? {
        guard arguments.count == parameterCount else { return nil }
        var slots = [RuntimeValue](repeating: .void, count: slotNames.count)
        for (index, value) in arguments.enumerated() {
            guard Self.isFixedWidthScalar(value) else { return nil }
            slots[index] = value
        }
        do {
            for earlyReturn in earlyReturns {
                let condition = try earlyReturn.condition.evaluate(
                    slots: slots, receiver: receiver,
                    interpreter: interpreter)
                guard let passes = condition.boolValue else { return nil }
                if !passes {
                    return try earlyReturn.value.evaluate(
                        slots: slots, receiver: receiver,
                        interpreter: interpreter)
                }
            }
            for initializer in initializers {
                let value = try initializer.expression.evaluate(
                    slots: slots, receiver: receiver,
                    interpreter: interpreter)
                guard Self.isFixedWidthScalar(value) else { return nil }
                slots[initializer.slot] = value
            }
            let value = try result.evaluate(
                slots: slots, receiver: receiver,
                interpreter: interpreter)
            return Self.isFixedWidthScalar(value) ? value : nil
        } catch is RuntimeFallback {
            return nil
        }
    }

    private static func isFixedWidthScalar(_ value: RuntimeValue) -> Bool {
        switch value {
        case .int, .double, .bool, .nilValue:
            return true
        case .optional(let optional):
            return optional.wrapped.map(isFixedWidthScalar) ?? true
        case .host(let payload):
            return payload is UInt64
        default:
            return false
        }
    }

    fileprivate static func compile(
        _ closure: ClosureValue, interpreter: Interpreter
    ) -> PreparedScalarFunction? {
        guard !closure.isBuilder,
              closure.genericParameters.isEmpty,
              closure.parameters.allSatisfy({
                  scalarTypeNames.contains(canonicalTypeName($0.typeName))
                      && $0.defaultValue == nil
                      && !$0.isBuilderAttributed
                      && !$0.isVariadic
                      && !$0.isIsolated
              }),
              closure.body.count <= 12 else { return nil }

        let compiler = Compiler(closure: closure, interpreter: interpreter)
        return compiler.compile()
    }

    private static let scalarTypeNames: Set<String> = [
        "Bool", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Float", "Double",
    ]

    private static func canonicalTypeName(_ typeName: String?) -> String {
        var name = typeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.hasPrefix("Swift.") { name.removeFirst("Swift.".count) }
        return name
    }

    @MainActor
    private final class Compiler {
        private let closure: ClosureValue
        private unowned let interpreter: Interpreter
        private var slotNames: [String]
        private var slotsByName: [String: Int]
        private var earlyReturns: [EarlyReturn] = []
        private var initializers: [Initializer] = []

        init(closure: ClosureValue, interpreter: Interpreter) {
            self.closure = closure
            self.interpreter = interpreter
            slotNames = closure.parameters.map(\.name)
            slotsByName = Dictionary(uniqueKeysWithValues:
                slotNames.enumerated().map { ($0.element, $0.offset) })
        }

        func compile() -> PreparedScalarFunction? {
            var returnExpression: Expression?
            for item in closure.body {
                switch item.item {
                case .decl(let declaration):
                    guard returnExpression == nil,
                          compileDeclaration(declaration) else { return nil }
                case .stmt(let statement):
                    guard returnExpression == nil else { return nil }
                    if let guardStatement = statement.as(GuardStmtSyntax.self) {
                        guard initializers.isEmpty,
                              compileLeadingGuard(guardStatement) else {
                            return nil
                        }
                    } else if let expressionStatement = statement.as(
                                ExpressionStmtSyntax.self),
                              let compiled = compileExpression(
                                expressionStatement.expression) {
                        returnExpression = compiled
                    } else {
                        guard let returnStatement =
                                statement.as(ReturnStmtSyntax.self),
                              let expression = returnStatement.expression,
                              let compiled = compileExpression(expression) else {
                            return nil
                        }
                        returnExpression = compiled
                    }
                case .expr(let expression):
                    guard returnExpression == nil,
                          let compiled = compileExpression(expression) else {
                        return nil
                    }
                    returnExpression = compiled
                }
            }
            guard let returnExpression else { return nil }
            return PreparedScalarFunction(
                slotNames: slotNames,
                parameterCount: closure.parameters.count,
                earlyReturns: earlyReturns,
                initializers: initializers,
                result: returnExpression)
        }

        private func compileLeadingGuard(_ statement: GuardStmtSyntax) -> Bool {
            guard statement.conditions.count == 1,
                  let element = statement.conditions.first,
                  case .expression(let conditionSyntax) = element.condition,
                  let condition = compileExpression(conditionSyntax),
                  statement.body.statements.count == 1,
                  let item = statement.body.statements.first,
                  case .stmt(let syntax) = item.item,
                  let returnStatement = syntax.as(ReturnStmtSyntax.self),
                  let valueSyntax = returnStatement.expression,
                  let value = compileExpression(valueSyntax) else {
                return false
            }
            earlyReturns.append(.init(condition: condition, value: value))
            return true
        }

        private func compileDeclaration(_ declaration: DeclSyntax) -> Bool {
            guard let variable = declaration.as(VariableDeclSyntax.self),
                  variable.attributes.isEmpty,
                  variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  binding.accessorBlock == nil,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  !slotsByName.keys.contains(identifier.identifier.text),
                  let value = binding.initializer?.value,
                  let expression = compileExpression(value) else { return false }
            if let annotation = binding.typeAnnotation?.type.trimmedDescription,
               !PreparedScalarFunction.scalarTypeNames.contains(
                    PreparedScalarFunction.canonicalTypeName(annotation)) {
                return false
            }
            let slot = slotNames.count
            slotNames.append(identifier.identifier.text)
            slotsByName[identifier.identifier.text] = slot
            initializers.append(.init(slot: slot, expression: expression))
            return true
        }

        private func compileExpression(_ expression: ExprSyntax) -> Expression? {
            switch expression.kind {
            case .nilLiteralExpr:
                return .constant(.nilValue)
            case .integerLiteralExpr:
                guard let value = try? interpreter.integerLiteralValue(
                    of: expression.cast(IntegerLiteralExprSyntax.self)) else {
                    return nil
                }
                return .constant(value)
            case .floatLiteralExpr:
                let literal = expression.cast(FloatLiteralExprSyntax.self)
                guard let value = Double(
                    literal.literal.text.filter { $0 != "_" }) else { return nil }
                return .constant(.native(value))
            case .booleanLiteralExpr:
                return .constant(.native(
                    expression.cast(BooleanLiteralExprSyntax.self)
                        .literal.text == "true"))
            case .declReferenceExpr:
                let name = expression.cast(DeclReferenceExprSyntax.self)
                    .baseName.text
                if let slot = slotsByName[name] { return .slot(slot) }
                if name == "self",
                   let value = closure.captured.lookup("self"),
                   PreparedScalarFunction.isFixedWidthScalar(value) {
                    return .receiver
                }
                guard case .instance(let instance)? =
                        closure.captured.lookup("self"),
                      instance.symbol.storedProperty(named: name) != nil else {
                    return nil
                }
                return .instanceMember(name, expression)
            case .memberAccessExpr:
                let member = expression.cast(MemberAccessExprSyntax.self)
                guard let base = member.base?.as(
                    DeclReferenceExprSyntax.self) else { return nil }
                let name = member.declName.baseName.text
                let owner: StaticOwner?
                if base.baseName.text == "Self" {
                    if let symbol = closure.lexicalOwner as? StructSymbol {
                        owner = .structure(symbol)
                    } else if let symbol = closure.lexicalOwner as? EnumSymbol {
                        owner = .enumeration(symbol)
                    } else {
                        owner = nil
                    }
                } else {
                    let lexical = closure.lexicalOwner as? StructSymbol
                    switch interpreter.typeValue(
                        named: base.baseName.text, within: lexical) {
                    case .type(let symbol): owner = .structure(symbol)
                    case .enumType(let symbol): owner = .enumeration(symbol)
                    default: owner = nil
                    }
                }
                guard let owner else { return nil }
                switch owner {
                case .structure(let symbol):
                    guard symbol.staticProperties[name] != nil,
                          symbol.staticComputedProperties[name] == nil else {
                        return nil
                    }
                case .enumeration(let symbol):
                    guard symbol.staticProperties[name] != nil,
                          symbol.staticComputedProperties[name] == nil else {
                        return nil
                    }
                }
                return .staticMember(owner, name, expression)
            case .subscriptCallExpr:
                let call = expression.cast(SubscriptCallExprSyntax.self)
                guard call.arguments.count == 1,
                      call.arguments.first?.label == nil,
                      let indexSyntax = call.arguments.first?.expression,
                      let base = compileExpression(call.calledExpression),
                      let index = compileExpression(indexSyntax) else {
                    return nil
                }
                return .integerSubscript(base, index, call)
            case .switchExpr:
                return compileScalarSwitch(
                    expression.cast(SwitchExprSyntax.self))
            case .infixOperatorExpr:
                let infix = expression.cast(InfixOperatorExprSyntax.self)
                guard let binary = infix.operator.as(BinaryOperatorExprSyntax.self),
                      Self.supportedOperators.contains(binary.operator.text),
                      let lhs = compileExpression(infix.leftOperand),
                      let rhs = compileExpression(infix.rightOperand) else {
                    return nil
                }
                return .binary(binary.operator.text, lhs, rhs, expression)
            case .prefixOperatorExpr:
                let prefix = expression.cast(PrefixOperatorExprSyntax.self)
                guard Self.supportedPrefixes.contains(prefix.operator.text),
                      let operand = compileExpression(prefix.expression) else {
                    return nil
                }
                return .prefix(prefix.operator.text, operand, expression)
            case .tupleExpr:
                let tuple = expression.cast(TupleExprSyntax.self)
                guard tuple.elements.count == 1,
                      let element = tuple.elements.first,
                      element.label == nil,
                      element.trailingComma == nil else { return nil }
                return compileExpression(element.expression)
            default:
                return nil
            }
        }

        /// Admit only value switches whose subject, patterns, and branch
        /// results are themselves in the scalar expression grammar. Pattern
        /// bindings, `where`, fallthrough, and multi-statement arms retain the
        /// full evaluator path.
        private func compileScalarSwitch(
            _ expression: SwitchExprSyntax
        ) -> Expression? {
            guard let subject = compileExpression(expression.subject) else {
                return nil
            }
            var branches: [ScalarSwitchCase] = []
            var hasDefault = false
            for switchCase in interpreter.flattenedSwitchCases(expression) {
                guard let result = compileScalarSwitchResult(
                    switchCase.statements) else { return nil }
                switch switchCase.label {
                case .default:
                    guard !hasDefault else { return nil }
                    hasDefault = true
                    branches.append(.init(patterns: nil, result: result))
                case .case(let label):
                    var patterns: [Expression] = []
                    patterns.reserveCapacity(label.caseItems.count)
                    for item in label.caseItems {
                        guard item.whereClause == nil,
                              let pattern = item.pattern.as(
                                ExpressionPatternSyntax.self),
                              let compiled = compileExpression(
                                pattern.expression) else {
                            return nil
                        }
                        patterns.append(compiled)
                    }
                    guard !patterns.isEmpty else { return nil }
                    branches.append(.init(
                        patterns: patterns, result: result))
                }
            }
            guard !branches.isEmpty else { return nil }
            return .scalarSwitch(subject, branches, expression)
        }

        private func compileScalarSwitchResult(
            _ statements: CodeBlockItemListSyntax
        ) -> Expression? {
            guard statements.count == 1,
                  let item = statements.first else { return nil }
            switch item.item {
            case .stmt(let statement):
                guard let returnStatement = statement.as(
                    ReturnStmtSyntax.self),
                      let expression = returnStatement.expression else {
                    return nil
                }
                return compileExpression(expression)
            case .expr(let expression):
                return compileExpression(expression)
            case .decl:
                return nil
            }
        }

        private static let supportedOperators: Set<String> = [
            "+", "-", "*", "/", "%", "&+", "&-", "&*",
            "&", "|", "^", "<<", ">>",
            "==", "!=", "<", "<=", ">", ">=", "&&", "||",
        ]
        private static let supportedPrefixes: Set<String> = ["-", "!", "~"]
    }
}

extension Interpreter {
    func preparedScalarFunction(
        for closure: ClosureValue
    ) -> PreparedScalarFunction? {
        guard let declarationID = closure.functionDeclID else { return nil }
        guard let state = closure.programState else { return nil }
        if let cached = state.preparedScalarFunctions[declarationID] {
            switch cached {
            case .unavailable: return nil
            case .prepared(let function): return function
            }
        }
        guard let function = PreparedScalarFunction.compile(
            closure, interpreter: self) else {
            state.preparedScalarFunctions[declarationID] = .unavailable
            return nil
        }
        state.preparedScalarFunctions[declarationID] = .prepared(function)
        return function
    }

    /// Computed accessors share the declaration-keyed scalar cache with
    /// functions. The short-lived closure exists only on the first access to
    /// project the accessor's syntax and lexical provenance into the common
    /// structural compiler; cache hits execute directly with the current
    /// receiver.
    func preparedScalarAccessor(
        _ computed: ComputedProperty, captured: Environment
    ) -> PreparedScalarFunction? {
        guard !computed.isBuilder, !computed.isAsync,
              let declarationID = computed.declarationID,
              let state = currentProgramState else { return nil }
        if let cached = state.preparedScalarFunctions[declarationID] {
            switch cached {
            case .unavailable: return nil
            case .prepared(let function): return function
            }
        }
        let closure = ClosureValue(
            parameters: [], body: computed.accessor, captured: captured,
            returnType: computed.typeAnnotation,
            programMetadata: currentProgramMetadata,
            programPlan: currentProgramPlan)
        closure.functionDeclID = declarationID
        closure.lexicalOwner = state.lexicalOwner(of: declarationID)
            ?? lexicalOwnerFrames.last
        closure.programState = state
        return preparedScalarFunction(for: closure)
    }

    func preparedScalarArguments(
        of closure: ClosureValue, from arguments: CallArguments
    ) throws -> [RuntimeValue]? {
        let matched = matchedParameterArguments(of: closure, to: arguments)
        guard matched.count == closure.parameters.count else { return nil }
        var values: [RuntimeValue] = []
        values.reserveCapacity(matched.count)
        for (parameter, candidate) in zip(closure.parameters, matched) {
            guard let candidate, candidate.inoutSlot == nil else { return nil }
            values.append(try resolveAnnotated(candidate, parameter: parameter))
        }
        return values
    }
}
