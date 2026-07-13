import Foundation
import SwiftSyntax

/// Typed scalar storage used by prepared finite-loop IR.
///
/// A plan may write only ordinary strong Boxes without observers. That makes
/// delayed materialization unobservable while removing RuntimeValue traffic
/// from the repeated path. Read-only observed Boxes are safe: fallback blocks
/// run through a synchronization boundary and refresh the cached value.
fileprivate final class PreparedIntSlot {
    let box: Box
    var value: Int
    private var dirty = false
    private var observedMutationVersion: UInt64

    init?(box: Box) {
        guard box.referenceOwnership == .strong,
              let value = box.value.intValue else { return nil }
        self.box = box
        self.value = value
        self.observedMutationVersion = box.mutationVersion
    }

    @inline(__always)
    func store(_ newValue: Int) {
        value = newValue
        dirty = true
    }

    func flush() {
        guard dirty else { return }
        box.value = .native(value)
        observedMutationVersion = box.mutationVersion
        dirty = false
    }

    /// Refresh after ordinary evaluator execution. Clearing `dirty` even for
    /// an incompatible value prevents an error-path flush from overwriting a
    /// source-visible mutation made by that evaluator.
    func refresh() -> Bool {
        dirty = false
        guard observedMutationVersion != box.mutationVersion else { return true }
        observedMutationVersion = box.mutationVersion
        guard let current = box.value.intValue else { return false }
        value = current
        return true
    }
}

/// A read-only snapshot of an integer collection referenced by prepared IR.
/// It is refreshed after every ordinary fallback block, so mutations through
/// aliases or source subscript assignment become visible before execution
/// returns to the prepared path.
fileprivate final class PreparedIntCollection {
    private enum Storage {
        case array([Int])
        case data(Data)
    }

    private let box: Box
    private var storage: Storage
    private var observedMutationVersion: UInt64

    init?(box: Box) {
        guard box.referenceOwnership == .strong,
              let storage = Self.storage(from: box.value) else { return nil }
        self.box = box
        self.storage = storage
        self.observedMutationVersion = box.mutationVersion
    }

    func refresh() -> Bool {
        guard observedMutationVersion != box.mutationVersion else { return true }
        observedMutationVersion = box.mutationVersion
        guard let storage = Self.storage(from: box.value) else { return false }
        self.storage = storage
        return true
    }

    @inline(__always)
    func element(
        at index: Int,
        node: SubscriptCallExprSyntax,
        interpreter: Interpreter
    ) throws -> Int {
        switch storage {
        case .array(let values):
            guard values.indices.contains(index) else {
                throw interpreter.error(node, "integer array index out of range")
            }
            return values[index]
        case .data(let data):
            guard index >= 0, index < data.count else {
                throw interpreter.error(node, "Data index \(index) out of range")
            }
            let position = data.index(data.startIndex, offsetBy: index)
            return Int(data[position])
        }
    }

    private static func storage(from value: RuntimeValue) -> Storage? {
        switch value {
        case .array(let values):
            var integers: [Int] = []
            integers.reserveCapacity(values.count)
            for value in values {
                guard let integer = value.intValue else { return nil }
                integers.append(integer)
            }
            return .array(integers)
        case .host(let payload) where payload is Data:
            return .data(payload as! Data)
        default:
            return nil
        }
    }
}

fileprivate final class PreparedLoopState {
    private let integerSlots: [PreparedIntSlot]
    private let integerCollections: [PreparedIntCollection]

    init(
        integerSlots: [PreparedIntSlot],
        integerCollections: [PreparedIntCollection]
    ) {
        self.integerSlots = integerSlots
        self.integerCollections = integerCollections
    }

    func flush() {
        for slot in integerSlots { slot.flush() }
    }

    /// Refresh every cache even if one value is incompatible. This leaves the
    /// complete state coherent on failure and avoids restoring stale values in
    /// the enclosing plan's defer.
    func refresh() -> Bool {
        var compatible = true
        for slot in integerSlots where !slot.refresh() { compatible = false }
        for collection in integerCollections where !collection.refresh() {
            compatible = false
        }
        return compatible
    }
}

/// A compact execution plan for large, straight-line integer loops.
///
/// Tree walking is the correct general evaluator, but repeatedly decoding the
/// same SwiftSyntax nodes dominates tight image/audio/data loops. This plan is
/// deliberately semantic rather than source-specific: it prepares scalar
/// bindings, integer arithmetic/comparisons, integer collection subscripts,
/// and simple conditional branches once.
///
/// Preparation of the repeated path is all-or-nothing. A supported condition
/// may enter an ordinary evaluator block through an explicit synchronization
/// boundary. Any other unsupported syntax rejects the plan, so this remains an
/// optimization and never becomes an alternate acceptance path for source.
final class PreparedFiniteLoop {
    private let environment: Environment
    private let elements: [Int]
    private let loopVariable: PreparedIntSlot?
    private let statements: [PreparedLoopStatement]
    private let state: PreparedLoopState

    fileprivate init(
        environment: Environment,
        elements: [Int],
        loopVariable: PreparedIntSlot?,
        statements: [PreparedLoopStatement],
        state: PreparedLoopState
    ) {
        self.environment = environment
        self.elements = elements
        self.loopVariable = loopVariable
        self.statements = statements
        self.state = state
    }

    /// Execute the complete materialized sequence. Owning this loop removes
    /// RuntimeValue element assignment and evaluator-plan dispatch from every
    /// iteration while retaining cancellation and control-flow boundaries.
    func execute(interpreter: Interpreter) throws -> StatementResult {
        defer { state.flush() }

        loop: for (iteration, element) in elements.enumerated() {
            if iteration & 63 == 0 { try interpreter.checkRuntimeCancellation() }
            loopVariable?.store(element)
            for statement in statements {
                let result = try statement.execute(
                    interpreter: interpreter,
                    environment: environment,
                    state: state)
                switch result {
                case .normal:
                    continue
                case .continueLoop:
                    continue loop
                case .breakLoop:
                    return .normal(.void)
                case .returnValue:
                    return result
                }
            }
        }
        return .normal(.void)
    }

    func executeSuspending(interpreter: Interpreter) async throws -> StatementResult {
        defer { state.flush() }

        loop: for (iteration, element) in elements.enumerated() {
            if iteration & 63 == 0 { try interpreter.checkRuntimeCancellation() }
            loopVariable?.store(element)
            for statement in statements {
                let result = try await statement.executeSuspending(
                    interpreter: interpreter,
                    environment: environment,
                    state: state)
                switch result {
                case .normal:
                    continue
                case .continueLoop:
                    continue loop
                case .breakLoop:
                    return .normal(.void)
                case .returnValue:
                    return result
                }
            }
        }
        return .normal(.void)
    }
}

fileprivate enum PreparedLoopStatement {
    case store(PreparedIntSlot, PreparedIntExpression)
    case compound(
        PreparedIntSlot, Builtins.IntBinaryOperation,
        PreparedIntExpression, InfixOperatorExprSyntax)
    case conditional(
        PreparedBoolExpression,
        PreparedConditionalBody,
        IfExprSyntax)

    func execute(
        interpreter: Interpreter,
        environment: Environment,
        state: PreparedLoopState
    ) throws -> StatementResult {
        switch self {
        case .store(let slot, let expression):
            slot.store(try expression.evaluate(interpreter))
            return .normal(.void)

        case .compound(let slot, let operation, let expression, let node):
            let rhs = try expression.evaluate(interpreter)
            let combined = try preparedApply(
                operation, slot.value, rhs, node: node, interpreter: interpreter)
            slot.store(combined)
            return .normal(.void)

        case .conditional(let condition, let body, let node):
            guard try condition.evaluate(interpreter) else {
                return .normal(.void)
            }
            if case .prepared(let statements) = body {
                for statement in statements {
                    let result = try statement.execute(
                        interpreter: interpreter,
                        environment: environment,
                        state: state)
                    if case .normal = result { continue }
                    return result
                }
                return .normal(.void)
            }
            guard case .fallback(let syntax) = body else {
                return .normal(.void)
            }
            state.flush()
            do {
                let result = try interpreter.withFiniteIterationSlice {
                    try interpreter.executeBlock(
                        syntax, in: Environment(parent: environment))
                }
                guard state.refresh() else {
                    throw interpreter.error(
                        node,
                        "prepared loop fallback changed cached integer storage "
                            + "to an incompatible value")
                }
                return result
            } catch {
                _ = state.refresh()
                throw error
            }
        }
    }

    func executeSuspending(
        interpreter: Interpreter,
        environment: Environment,
        state: PreparedLoopState
    ) async throws -> StatementResult {
        switch self {
        case .conditional(let condition, let body, let node):
            guard try condition.evaluate(interpreter) else {
                return .normal(.void)
            }
            if case .prepared(let statements) = body {
                for statement in statements {
                    let result = try await statement.executeSuspending(
                        interpreter: interpreter,
                        environment: environment,
                        state: state)
                    if case .normal = result { continue }
                    return result
                }
                return .normal(.void)
            }
            guard case .fallback(let syntax) = body else {
                return .normal(.void)
            }
            state.flush()
            do {
                let result = try await interpreter.withFiniteIterationSlice {
                    try await interpreter.executeBlockSuspending(
                        syntax, in: Environment(parent: environment))
                }
                guard state.refresh() else {
                    throw interpreter.error(
                        node,
                        "prepared loop fallback changed cached integer storage "
                            + "to an incompatible value")
                }
                return result
            } catch {
                _ = state.refresh()
                throw error
            }
        default:
            return try execute(
                interpreter: interpreter,
                environment: environment,
                state: state)
        }
    }
}

fileprivate enum PreparedConditionalBody {
    case prepared([PreparedLoopStatement])
    case fallback(CodeBlockItemListSyntax)
}

fileprivate indirect enum PreparedIntExpression {
    case constant(Int)
    case slot(PreparedIntSlot)
    case collectionElement(
        PreparedIntCollection, PreparedIntExpression, SubscriptCallExprSyntax)
    case binary(
        Builtins.IntBinaryOperation,
        PreparedIntExpression,
        PreparedIntExpression,
        InfixOperatorExprSyntax)
    case minimum(PreparedIntExpression, PreparedIntExpression)
    case maximum(PreparedIntExpression, PreparedIntExpression)
    case negated(PreparedIntExpression, PrefixOperatorExprSyntax)

    @inline(__always)
    func evaluate(_ interpreter: Interpreter) throws -> Int {
        switch self {
        case .constant(let value):
            return value

        case .slot(let slot):
            return slot.value

        case .collectionElement(let collection, let indexExpression, let node):
            let index = try indexExpression.evaluate(interpreter)
            return try collection.element(
                at: index, node: node, interpreter: interpreter)

        case .binary(let operation, let lhs, let rhs, let node):
            let left = try lhs.evaluate(interpreter)
            let right = try rhs.evaluate(interpreter)
            return try preparedApply(
                operation, left, right, node: node, interpreter: interpreter)

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
            do {
                return try Builtins.fastIntNegation(value)
            } catch let message as EvalMessage {
                throw interpreter.error(node, message.text)
            }
        }
    }
}

/// Located adapter for the shared integer core. Keeping this as a direct call
/// avoids allocating a relocation closure for every prepared arithmetic node.
@inline(__always)
private func preparedApply(
    _ operation: Builtins.IntBinaryOperation,
    _ lhs: Int,
    _ rhs: Int,
    node: some SyntaxProtocol,
    interpreter: Interpreter
) throws -> Int {
    do {
        return try operation.apply(lhs, rhs)
    } catch let message as EvalMessage {
        throw interpreter.error(node, message.text)
    }
}

fileprivate indirect enum PreparedBoolExpression {
    case constant(Bool)
    case slot(Box, ExprSyntax)
    case comparison(
        Builtins.IntComparisonOperation,
        PreparedIntExpression,
        PreparedIntExpression)
    case and(PreparedBoolExpression, PreparedBoolExpression)
    case or(PreparedBoolExpression, PreparedBoolExpression)
    case not(PreparedBoolExpression)

    @inline(__always)
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
        case .comparison(let operation, let lhs, let rhs):
            let left = try lhs.evaluate(interpreter)
            let right = try rhs.evaluate(interpreter)
            return operation.apply(left, right)
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
    private let elements: [Int]
    private var localNames = Set<String>()
    private var slotsByBox: [ObjectIdentifier: PreparedIntSlot] = [:]
    private var slots: [PreparedIntSlot] = []
    private var collectionsByBox: [ObjectIdentifier: PreparedIntCollection] = [:]
    private var collections: [PreparedIntCollection] = []

    init(
        interpreter: Interpreter,
        parent: Environment,
        loopVariableName: String?,
        elements: [Int]
    ) {
        self.interpreter = interpreter
        self.elements = elements
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
        let loopVariable: PreparedIntSlot?
        if let loopVariableName {
            guard let box = environment.box(for: loopVariableName),
                  let slot = integerSlot(for: box, writable: true) else { return nil }
            loopVariable = slot
        } else {
            loopVariable = nil
        }
        let state = PreparedLoopState(
            integerSlots: slots,
            integerCollections: collections)
        return PreparedFiniteLoop(
            environment: environment,
            elements: elements,
            loopVariable: loopVariable,
            statements: statements,
            state: state)
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
        guard let box = environment.box(for: name),
              let slot = integerSlot(for: box, writable: true) else { return nil }
        return .store(slot, expression)
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
            let body: PreparedConditionalBody
            if let statements = compileConditionalBody(
                conditional.body.statements) {
                body = .prepared(statements)
            } else {
                body = .fallback(conditional.body.statements)
            }
            return .conditional(condition, body, conditional)
        }

        guard let infix = expression.as(InfixOperatorExprSyntax.self),
              let reference = infix.leftOperand.as(DeclReferenceExprSyntax.self),
              let box = environment.box(for: reference.baseName.text),
              let slot = integerSlot(for: box, writable: true) else { return nil }

        if infix.operator.is(AssignmentExprSyntax.self) {
            guard let rhs = compileInt(infix.rightOperand) else { return nil }
            return .store(slot, rhs)
        }
        guard let binary = infix.operator.as(BinaryOperatorExprSyntax.self),
              binary.operator.text.hasSuffix("="),
              let rhs = compileInt(infix.rightOperand),
              let operation = Builtins.IntBinaryOperation(
                rawValue: String(binary.operator.text.dropLast())) else { return nil }
        return .compound(slot, operation, rhs, infix)
    }

    /// A declaration-free branch has the same name-resolution environment as
    /// its parent and can stay entirely in typed IR. Declarations retain their
    /// ordinary lexical child scope through the fallback evaluator.
    private func compileConditionalBody(
        _ items: CodeBlockItemListSyntax
    ) -> [PreparedLoopStatement]? {
        var statements: [PreparedLoopStatement] = []
        statements.reserveCapacity(items.count)
        for item in items {
            if case .decl = item.item { return nil }
            guard let statement = compile(item) else { return nil }
            statements.append(statement)
        }
        return statements
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
                  let slot = integerSlot(for: box, writable: false) else { return nil }
            return .slot(slot)

        case .subscriptCallExpr:
            let call = expression.cast(SubscriptCallExprSyntax.self)
            guard call.arguments.count == 1,
                  call.arguments.first?.label == nil,
                  let base = call.calledExpression.as(DeclReferenceExprSyntax.self),
                  let box = environment.box(for: base.baseName.text),
                  let collection = integerCollection(for: box),
                  let indexExpression = call.arguments.first?.expression,
                  let index = compileInt(indexExpression) else { return nil }
            return .collectionElement(collection, index, call)

        case .infixOperatorExpr:
            let infix = expression.cast(InfixOperatorExprSyntax.self)
            guard let binary = infix.operator.as(BinaryOperatorExprSyntax.self),
                  let operation = Builtins.IntBinaryOperation(
                    rawValue: binary.operator.text),
                  let lhs = compileInt(infix.leftOperand),
                  let rhs = compileInt(infix.rightOperand) else { return nil }
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
            guard let comparison = Builtins.IntComparisonOperation(
                    rawValue: operation),
                  let lhs = compileInt(infix.leftOperand),
                  let rhs = compileInt(infix.rightOperand) else { return nil }
            return .comparison(comparison, lhs, rhs)

        default:
            return nil
        }
    }

    private func integerSlot(
        for box: Box,
        writable: Bool
    ) -> PreparedIntSlot? {
        guard box.referenceOwnership == .strong,
              !writable || box.onChange == nil else { return nil }
        let identifier = ObjectIdentifier(box)
        if let slot = slotsByBox[identifier] { return slot }
        guard let slot = PreparedIntSlot(box: box) else { return nil }
        slotsByBox[identifier] = slot
        slots.append(slot)
        return slot
    }

    private func integerCollection(for box: Box) -> PreparedIntCollection? {
        let identifier = ObjectIdentifier(box)
        if let collection = collectionsByBox[identifier] { return collection }
        guard let collection = PreparedIntCollection(box: box) else { return nil }
        collectionsByBox[identifier] = collection
        collections.append(collection)
        return collection
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
        guard elements.count >= Self.preparedFiniteLoopMinimumCount else { return nil }
        var integers: [Int] = []
        integers.reserveCapacity(elements.count)
        for element in elements {
            guard let integer = element.intValue else { return nil }
            integers.append(integer)
        }
        let plan = PreparedFiniteLoopCompiler(
            interpreter: self,
            parent: parent,
            loopVariableName: loopVariableName,
            elements: integers
        ).compile(body, loopVariableName: loopVariableName)
        if plan != nil { recordPreparedFiniteLoopPlan() }
        return plan
    }
}
