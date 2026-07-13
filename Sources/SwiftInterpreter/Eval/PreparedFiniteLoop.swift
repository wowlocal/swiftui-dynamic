import Foundation
import SwiftSyntax

/// A compact execution plan for large, straight-line integer loops.
///
/// Tree walking is the correct general evaluator, but repeatedly decoding the
/// same SwiftSyntax nodes dominates tight image/audio/data loops. This plan is
/// deliberately semantic rather than source-specific: it prepares scalar
/// bindings, integer arithmetic/comparisons, integer collection subscripts,
/// and simple conditional branches once, then reuses the ordinary Boxes and
/// fallback evaluator for everything outside that closed subset.
///
/// Preparation of the repeated path is all-or-nothing. The one explicit
/// boundary is a supported condition whose taken body runs through the regular
/// evaluator. Any other unsupported syntax rejects the plan, so this remains
/// an optimization and never becomes an alternate acceptance path for source.
final class PreparedFiniteLoop {
    private let environment: Environment
    private let loopVariable: Box?
    private let statements: [PreparedLoopStatement]

    fileprivate init(
        environment: Environment,
        loopVariable: Box?,
        statements: [PreparedLoopStatement]
    ) {
        self.environment = environment
        self.loopVariable = loopVariable
        self.statements = statements
    }

    func execute(element: RuntimeValue, interpreter: Interpreter) throws -> StatementResult {
        if let loopVariable {
            guard element.intValue != nil else {
                throw RuntimeError(message:
                    "prepared integer loop received a non-integer element")
            }
            loopVariable.value = element
        }
        for statement in statements {
            let result = try statement.execute(
                interpreter: interpreter, environment: environment)
            if case .normal = result { continue }
            return result
        }
        return .normal(.void)
    }

    func executeSuspending(
        element: RuntimeValue,
        interpreter: Interpreter
    ) async throws -> StatementResult {
        if let loopVariable {
            guard element.intValue != nil else {
                throw RuntimeError(message:
                    "prepared integer loop received a non-integer element")
            }
            loopVariable.value = element
        }
        for statement in statements {
            let result = try await statement.executeSuspending(
                interpreter: interpreter, environment: environment)
            if case .normal = result { continue }
            return result
        }
        return .normal(.void)
    }
}

fileprivate enum PreparedLoopStatement {
    case store(Box, PreparedIntExpression)
    case compound(Box, String, PreparedIntExpression, InfixOperatorExprSyntax)
    case conditional(
        PreparedBoolExpression,
        CodeBlockItemListSyntax)

    func execute(
        interpreter: Interpreter,
        environment: Environment
    ) throws -> StatementResult {
        switch self {
        case .store(let box, let expression):
            box.value = .native(try expression.evaluate(interpreter))
            return .normal(.void)

        case .compound(let box, let operation, let expression, let node):
            let current = try preparedInt(
                from: box, node: node, interpreter: interpreter)
            let rhs = try expression.evaluate(interpreter)
            let combined = try interpreter.relocating(node) {
                try Builtins.fastIntBinary(operation, current, rhs)
            }
            guard let combined else {
                throw interpreter.error(
                    node, "unsupported prepared integer operator '\(operation)'")
            }
            box.value = .native(combined)
            return .normal(.void)

        case .conditional(let condition, let body):
            guard try condition.evaluate(interpreter) else {
                return .normal(.void)
            }
            return try interpreter.executeBlock(
                body, in: Environment(parent: environment))
        }
    }

    func executeSuspending(
        interpreter: Interpreter,
        environment: Environment
    ) async throws -> StatementResult {
        switch self {
        case .conditional(let condition, let body):
            guard try condition.evaluate(interpreter) else {
                return .normal(.void)
            }
            return try await interpreter.executeBlockSuspending(
                body, in: Environment(parent: environment))
        default:
            return try execute(interpreter: interpreter, environment: environment)
        }
    }
}

fileprivate indirect enum PreparedIntExpression {
    case constant(Int)
    case slot(Box, ExprSyntax)
    case collectionElement(
        Box, PreparedIntExpression, SubscriptCallExprSyntax)
    case binary(
        String, PreparedIntExpression, PreparedIntExpression,
        InfixOperatorExprSyntax)
    case minimum(PreparedIntExpression, PreparedIntExpression)
    case maximum(PreparedIntExpression, PreparedIntExpression)
    case negated(PreparedIntExpression, PrefixOperatorExprSyntax)

    func evaluate(_ interpreter: Interpreter) throws -> Int {
        switch self {
        case .constant(let value):
            return value

        case .slot(let box, let node):
            return try preparedInt(from: box, node: node, interpreter: interpreter)

        case .collectionElement(let box, let indexExpression, let node):
            let index = try indexExpression.evaluate(interpreter)
            let collection = try box.load()
            if case .array(let values) = collection {
                guard values.indices.contains(index),
                      let value = values[index].intValue else {
                    throw interpreter.error(node, "integer array index out of range")
                }
                return value
            }
            if case .host(let payload) = collection, let data = payload as? Data {
                guard index >= 0, index < data.count else {
                    throw interpreter.error(node, "Data index \(index) out of range")
                }
                let position = data.index(data.startIndex, offsetBy: index)
                return Int(data[position])
            }
            throw interpreter.error(
                node, "prepared integer subscript needs an integer collection")

        case .binary(let operation, let lhs, let rhs, let node):
            let left = try lhs.evaluate(interpreter)
            let right = try rhs.evaluate(interpreter)
            let result = try interpreter.relocating(node) {
                try Builtins.fastIntBinary(operation, left, right)
            }
            guard let result else {
                throw interpreter.error(
                    node, "unsupported prepared integer operator '\(operation)'")
            }
            return result

        case .minimum(let lhs, let rhs):
            let left = try lhs.evaluate(interpreter)
            let right = try rhs.evaluate(interpreter)
            return min(left, right)

        case .maximum(let lhs, let rhs):
            let left = try lhs.evaluate(interpreter)
            let right = try rhs.evaluate(interpreter)
            return max(left, right)

        case .negated(let operand, let node):
            let value = try operand.evaluate(interpreter)
            return try interpreter.relocating(node) {
                try Builtins.fastIntNegation(value)
            }
        }
    }
}

fileprivate indirect enum PreparedBoolExpression {
    case constant(Bool)
    case slot(Box, ExprSyntax)
    case comparison(
        String, PreparedIntExpression, PreparedIntExpression,
        InfixOperatorExprSyntax)
    case and(PreparedBoolExpression, PreparedBoolExpression)
    case or(PreparedBoolExpression, PreparedBoolExpression)
    case not(PreparedBoolExpression)

    func evaluate(_ interpreter: Interpreter) throws -> Bool {
        switch self {
        case .constant(let value):
            return value
        case .slot(let box, let node):
            let value = try box.load()
            guard let flag = value.boolValue else {
                throw interpreter.error(
                    node, "prepared Boolean expression found \(value.stringified)")
            }
            return flag
        case .comparison(let operation, let lhs, let rhs, let node):
            let left = try lhs.evaluate(interpreter)
            let right = try rhs.evaluate(interpreter)
            guard let result = Builtins.fastIntComparison(operation, left, right) else {
                throw interpreter.error(
                    node, "unsupported prepared comparison '\(operation)'")
            }
            return result
        case .and(let lhs, let rhs):
            guard try lhs.evaluate(interpreter) else { return false }
            return try rhs.evaluate(interpreter)
        case .or(let lhs, let rhs):
            guard try !lhs.evaluate(interpreter) else { return true }
            return try rhs.evaluate(interpreter)
        case .not(let operand):
            return try !operand.evaluate(interpreter)
        }
    }
}

private func preparedInt(
    from box: Box,
    node: some SyntaxProtocol,
    interpreter: Interpreter
) throws -> Int {
    let value = try box.load()
    guard let integer = value.intValue else {
        throw interpreter.error(
            node, "prepared integer expression found \(value.stringified)")
    }
    return integer
}

private nonisolated final class PreparedLoopCaptureVisitor: SyntaxVisitor {
    var foundCapture = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        foundCapture = true
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        foundCapture = true
        return .skipChildren
    }

    override func visit(_ node: DeferStmtSyntax) -> SyntaxVisitorContinueKind {
        foundCapture = true
        return .skipChildren
    }
}

private final class PreparedFiniteLoopCompiler {
    private unowned let interpreter: Interpreter
    private let environment: Environment
    private var localNames = Set<String>()

    init(
        interpreter: Interpreter,
        parent: Environment,
        loopVariableName: String?
    ) {
        self.interpreter = interpreter
        environment = Environment(parent: parent)
        if let loopVariableName {
            environment.define(loopVariableName, .native(0))
            localNames.insert(loopVariableName)
        }
    }

    func compile(
        _ body: CodeBlockItemListSyntax,
        loopVariableName: String?
    ) -> PreparedFiniteLoop? {
        let captureVisitor = PreparedLoopCaptureVisitor()
        captureVisitor.walk(Syntax(body))
        guard !captureVisitor.foundCapture else { return nil }

        var statements: [PreparedLoopStatement] = []
        for item in body {
            guard let statement = compile(item) else { return nil }
            statements.append(statement)
        }
        let loopVariable = loopVariableName.flatMap { environment.box(for: $0) }
        return PreparedFiniteLoop(
            environment: environment,
            loopVariable: loopVariable,
            statements: statements)
    }

    private func compile(_ item: CodeBlockItemSyntax) -> PreparedLoopStatement? {
        switch item.item {
        case .decl(let declaration):
            return compileDeclaration(declaration)
        case .expr(let expression):
            return compileExpressionStatement(expression)
        case .stmt(let statement):
            guard let expression = statement.as(ExpressionStmtSyntax.self)?.expression else {
                return nil
            }
            return compileExpressionStatement(expression)
        }
    }

    private func compileDeclaration(_ declaration: DeclSyntax) -> PreparedLoopStatement? {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.attributes.isEmpty,
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              binding.accessorBlock == nil,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
              let initializer = binding.initializer?.value else { return nil }

        if let annotation = binding.typeAnnotation?.type.trimmedDescription,
           annotation != "Int" && annotation != "Swift.Int" {
            return nil
        }
        let name = identifier.identifier.text
        guard !localNames.contains(name),
              let expression = compileInt(initializer) else { return nil }
        environment.define(name, .native(0), declaredTypeName: "Int")
        localNames.insert(name)
        guard let box = environment.box(for: name) else { return nil }
        return .store(box, expression)
    }

    private func compileExpressionStatement(
        _ expression: ExprSyntax
    ) -> PreparedLoopStatement? {
        if let conditional = expression.as(IfExprSyntax.self) {
            guard conditional.elseBody == nil,
                  conditional.conditions.count == 1,
                  let firstCondition = conditional.conditions.first,
                  case .expression(let conditionExpression) = firstCondition.condition,
                  let condition = compileBool(conditionExpression) else { return nil }
            return .conditional(condition, conditional.body.statements)
        }

        guard let infix = expression.as(InfixOperatorExprSyntax.self),
              let reference = infix.leftOperand.as(DeclReferenceExprSyntax.self),
              let box = environment.box(for: reference.baseName.text) else { return nil }

        if infix.operator.is(AssignmentExprSyntax.self) {
            guard let rhs = compileInt(infix.rightOperand) else { return nil }
            return .store(box, rhs)
        }
        guard let binary = infix.operator.as(BinaryOperatorExprSyntax.self),
              binary.operator.text.hasSuffix("="),
              let rhs = compileInt(infix.rightOperand) else { return nil }
        let operation = String(binary.operator.text.dropLast())
        guard (try? Builtins.fastIntBinary(operation, 1, 1)) != nil else {
            return nil
        }
        return .compound(box, operation, rhs, infix)
    }

    private func compileInt(_ expression: ExprSyntax) -> PreparedIntExpression? {
        switch expression.kind {
        case .integerLiteralExpr:
            let literal = expression.cast(IntegerLiteralExprSyntax.self)
            guard let value = Int(literal.literal.text.filter { $0 != "_" }) else {
                return nil
            }
            return .constant(value)

        case .declReferenceExpr:
            let reference = expression.cast(DeclReferenceExprSyntax.self)
            guard let box = environment.box(for: reference.baseName.text),
                  box.value.intValue != nil else { return nil }
            return .slot(box, expression)

        case .subscriptCallExpr:
            let call = expression.cast(SubscriptCallExprSyntax.self)
            guard call.arguments.count == 1,
                  call.arguments.first?.label == nil,
                  let base = call.calledExpression.as(DeclReferenceExprSyntax.self),
                  let box = environment.box(for: base.baseName.text),
                  let indexExpression = call.arguments.first?.expression,
                  let index = compileInt(indexExpression) else { return nil }
            switch box.value {
            case .array:
                break
            case .host(let payload) where payload is Data:
                break
            default:
                return nil
            }
            return .collectionElement(box, index, call)

        case .infixOperatorExpr:
            let infix = expression.cast(InfixOperatorExprSyntax.self)
            guard let binary = infix.operator.as(BinaryOperatorExprSyntax.self),
                  let lhs = compileInt(infix.leftOperand),
                  let rhs = compileInt(infix.rightOperand) else { return nil }
            let operation = binary.operator.text
            guard (try? Builtins.fastIntBinary(operation, 1, 1)) != nil else {
                return nil
            }
            return .binary(operation, lhs, rhs, infix)

        case .functionCallExpr:
            let call = expression.cast(FunctionCallExprSyntax.self)
            guard let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) else {
                return nil
            }
            let intrinsic = resolvedIntrinsic(reference.baseName.text)
            if intrinsic == .intConversion,
               call.arguments.count == 1,
               call.arguments.first?.label == nil,
               let argument = call.arguments.first?.expression {
                return compileInt(argument)
            }
            guard intrinsic == .integerMinimum || intrinsic == .integerMaximum,
                  call.arguments.count == 2,
                  call.arguments.allSatisfy({ $0.label == nil }) else { return nil }
            let arguments = Array(call.arguments)
            guard let lhs = compileInt(arguments[0].expression),
                  let rhs = compileInt(arguments[1].expression) else { return nil }
            return intrinsic == .integerMinimum
                ? .minimum(lhs, rhs)
                : .maximum(lhs, rhs)

        case .prefixOperatorExpr:
            let prefix = expression.cast(PrefixOperatorExprSyntax.self)
            guard prefix.operator.text == "-",
                  let operand = compileInt(prefix.expression) else { return nil }
            return .negated(operand, prefix)

        case .tupleExpr:
            let tuple = expression.cast(TupleExprSyntax.self)
            guard tuple.elements.count == 1,
                  let element = tuple.elements.first,
                  element.label == nil,
                  element.trailingComma == nil else { return nil }
            return compileInt(element.expression)

        default:
            return nil
        }
    }

    private func compileBool(_ expression: ExprSyntax) -> PreparedBoolExpression? {
        switch expression.kind {
        case .booleanLiteralExpr:
            let literal = expression.cast(BooleanLiteralExprSyntax.self)
            return .constant(literal.literal.text == "true")

        case .declReferenceExpr:
            let reference = expression.cast(DeclReferenceExprSyntax.self)
            guard let box = environment.box(for: reference.baseName.text),
                  box.value.boolValue != nil else { return nil }
            return .slot(box, expression)

        case .prefixOperatorExpr:
            let prefix = expression.cast(PrefixOperatorExprSyntax.self)
            guard prefix.operator.text == "!",
                  let operand = compileBool(prefix.expression) else { return nil }
            return .not(operand)

        case .infixOperatorExpr:
            let infix = expression.cast(InfixOperatorExprSyntax.self)
            guard let binary = infix.operator.as(BinaryOperatorExprSyntax.self) else {
                return nil
            }
            let operation = binary.operator.text
            if operation == "&&" || operation == "||" {
                guard let lhs = compileBool(infix.leftOperand),
                      let rhs = compileBool(infix.rightOperand) else { return nil }
                return operation == "&&" ? .and(lhs, rhs) : .or(lhs, rhs)
            }
            guard Builtins.fastIntComparison(operation, 0, 0) != nil,
                  let lhs = compileInt(infix.leftOperand),
                  let rhs = compileInt(infix.rightOperand) else { return nil }
            return .comparison(operation, lhs, rhs, infix)

        default:
            return nil
        }
    }

    private func resolvedIntrinsic(_ name: String) -> CoreFunctionIntrinsic? {
        guard let box = environment.box(for: name),
              case .hostFunction(let function) = box.value else { return nil }
        return interpreter.coreFunctionIntrinsic(for: function)
    }
}

extension Interpreter {
    static let preparedFiniteLoopMinimumCount = 256

    func prepareFiniteIntegerLoop(
        body: CodeBlockItemListSyntax,
        loopVariableName: String?,
        parent: Environment,
        elements: [RuntimeValue]
    ) -> PreparedFiniteLoop? {
        guard elements.count >= Self.preparedFiniteLoopMinimumCount,
              elements.allSatisfy({ $0.intValue != nil }) else { return nil }
        let plan = PreparedFiniteLoopCompiler(
            interpreter: self,
            parent: parent,
            loopVariableName: loopVariableName
        ).compile(body, loopVariableName: loopVariableName)
        if plan != nil { recordPreparedFiniteLoopPlan() }
        return plan
    }
}
