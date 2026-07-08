import SwiftSyntax

/// Expression evaluation: the big dispatch over folded `ExprSyntax`.
extension Interpreter {
    func evaluate(_ expr: ExprSyntax, in env: Environment) throws -> RuntimeValue {
        try tick(expr)

        if let lit = expr.as(IntegerLiteralExprSyntax.self) {
            return .native(try integerValue(of: lit))
        }
        if let lit = expr.as(FloatLiteralExprSyntax.self) {
            guard let d = Double(lit.literal.text.filter { $0 != "_" }) else {
                throw error(lit, "invalid float literal")
            }
            return .native(d)
        }
        if let lit = expr.as(BooleanLiteralExprSyntax.self) {
            return .native(lit.literal.text == "true")
        }
        if expr.is(NilLiteralExprSyntax.self) {
            return .nilValue
        }
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            return .native(try stringLiteral(lit, in: env))
        }
        if let array = expr.as(ArrayExprSyntax.self) {
            return .native(try array.elements.map { try evaluate($0.expression, in: env) })
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return try resolveIdentifier(ref.baseName.text, in: env, node: ref)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else {
                return .implicitMember(member.declName.baseName.text)
            }
            let baseValue = try evaluate(base, in: env)
            return try accessMember(member.declName.baseName.text, on: baseValue, node: member, env: env)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return try evaluateCall(call, in: env)
        }
        if let closure = expr.as(ClosureExprSyntax.self) {
            return .closure(makeClosure(closure, in: env))
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return try evaluateInfix(infix, in: env)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            let operand = try evaluate(prefix.expression, in: env)
            return try relocating(prefix) { try Builtins.prefix(prefix.operator.text, operand) }
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            let condition = try expectBool(evaluate(ternary.condition, in: env), node: ternary.condition)
            return try evaluate(condition ? ternary.thenExpression : ternary.elseExpression, in: env)
        }
        if let tuple = expr.as(TupleExprSyntax.self) {
            guard tuple.elements.count == 1, let only = tuple.elements.first else {
                throw error(tuple, "tuples aren't supported")
            }
            return try evaluate(only.expression, in: env)
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            return try evaluateSubscript(subscriptCall, in: env)
        }
        if expr.is(KeyPathExprSyntax.self) {
            return .native(KeyPathStub())
        }
        if let ifExpr = expr.as(IfExprSyntax.self) {
            if case .normal(let value) = try executeIf(ifExpr, in: env) { return value }
            throw error(ifExpr, "control flow can't escape an if-expression")
        }
        if expr.is(SequenceExprSyntax.self) {
            throw error(expr, "internal error: unfolded operator sequence")
        }
        throw error(expr, "unsupported expression (\(expr.kind))")
    }

    // MARK: - Identifiers & members

    func resolveIdentifier(_ name: String, in env: Environment, node: some SyntaxProtocol) throws -> RuntimeValue {
        if let value = env.lookup(name) { return value }
        if let instance = currentSelf(in: env),
           let value = try instanceMember(name, on: instance) {
            return value
        }
        if let ctor = registry?.constructor(named: name) {
            return .hostFunction(ctor)
        }
        throw error(node, "unresolved identifier '\(name)'")
    }

    func currentSelf(in env: Environment) -> Instance? {
        if case .instance(let instance)? = env.lookup("self") { return instance }
        return nil
    }

    /// Property → method → computed property, or nil if the name is unknown.
    func instanceMember(_ name: String, on instance: Instance) throws -> RuntimeValue? {
        if let box = instance.box(for: name) { return box.value }
        if let method = instance.symbol.methods[name] {
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: methodEnvironment(for: instance)))
        }
        if let accessor = instance.symbol.computedProperties[name] {
            let result = try executeBlock(accessor, in: methodEnvironment(for: instance))
            switch result {
            case .normal(let value), .returnValue(let value): return value
            default: throw RuntimeError(message: "control flow escaped computed property '\(name)'")
            }
        }
        return nil
    }

    func accessMember(_ name: String, on baseValue: RuntimeValue, node: some SyntaxProtocol, env: Environment) throws -> RuntimeValue {
        switch baseValue {
        case .instance(let instance):
            if let value = try instanceMember(name, on: instance) { return value }
            // A modifier applied to an interpreted View: wrap it renderable first.
            if instance.symbol.conformsToView, let registry,
               let modifier = registry.modifier(named: name) {
                let wrapped = registry.makeRenderable(instance: instance, interpreter: self)
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(wrapped, args, ctx)
                })
            }
            throw error(node, "'\(instance.symbol.name)' has no member '\(name)'")

        case .native(let any):
            if let array = any as? [RuntimeValue] {
                switch name {
                case "count": return .native(array.count)
                case "isEmpty": return .native(array.isEmpty)
                case "first": return array.first ?? .nilValue
                case "last": return array.last ?? .nilValue
                case "indices": return .native(0..<array.count)
                default: break
                }
            }
            if let string = any as? String {
                switch name {
                case "count": return .native(string.count)
                case "isEmpty": return .native(string.isEmpty)
                case "uppercased":
                    return .hostFunction(HostFunction(name: "uppercased") { _, _ in .native(string.uppercased()) })
                case "lowercased":
                    return .hostFunction(HostFunction(name: "lowercased") { _, _ in .native(string.lowercased()) })
                default: break
                }
            }
            if let registry, registry.isViewValue(baseValue), let modifier = registry.modifier(named: name) {
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(baseValue, args, ctx)
                })
            }
            throw error(node, "unsupported member '\(name)' on \(type(of: any))")

        case .type(let symbol):
            throw error(node, "static members of '\(symbol.name)' aren't supported")

        default:
            throw error(node, "cannot access member '\(name)' on \(baseValue.stringified)")
        }
    }

    // MARK: - Calls

    func evaluateCall(_ call: FunctionCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        // `.system(size: 40)` — implicit member call, resolved later by a gateway.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil {
            let args = try collectArguments(of: call, in: env)
            return .native(ImplicitMemberCall(name: member.declName.baseName.text, arguments: args))
        }
        let callee = try evaluate(call.calledExpression, in: env)
        let args = try collectArguments(of: call, in: env)
        return try invoke(callee, with: args, node: call)
    }

    func collectArguments(of call: FunctionCallExprSyntax, in env: Environment) throws -> CallArguments {
        var arguments: [CallArguments.Argument] = []
        for labeled in call.arguments {
            arguments.append(.init(label: labeled.label?.text, value: try evaluate(labeled.expression, in: env)))
        }
        if let trailing = call.trailingClosure {
            arguments.append(.init(label: nil, value: .closure(makeClosure(trailing, in: env)), isTrailing: true))
        }
        for extra in call.additionalTrailingClosures {
            arguments.append(.init(label: extra.label.text, value: .closure(makeClosure(extra.closure, in: env)), isTrailing: true))
        }
        return CallArguments(arguments: arguments)
    }

    func invoke(_ callee: RuntimeValue, with args: CallArguments, node: some SyntaxProtocol) throws -> RuntimeValue {
        switch callee {
        case .type(let symbol):
            return try instantiate(symbol, with: args, node: Syntax(node))
        case .closure(let closure):
            return try callWithArguments(closure, args: args, node: Syntax(node))
        case .hostFunction(let function):
            do {
                return try function.invoke(args, self)
            } catch let e as RuntimeError where e.line == 0 {
                // Gateways throw unlocated errors; pin them to the call site.
                throw error(node, e.message)
            }
        case .implicitMember(let name):
            return .native(ImplicitMemberCall(name: name, arguments: args))
        default:
            throw error(node, "\(callee.stringified) is not callable")
        }
    }

    func makeClosure(_ closure: ClosureExprSyntax, in env: Environment) -> ClosureValue {
        var parameters: [ClosureValue.Parameter] = []
        if let input = closure.signature?.parameterClause {
            switch input {
            case .simpleInput(let shorthand):
                parameters = shorthand.map { .init(name: $0.name.text) }
            case .parameterClause(let clause):
                parameters = clause.parameters.map { .init(name: ($0.secondName ?? $0.firstName).text) }
            }
        }
        return ClosureValue(parameters: parameters, body: closure.statements, captured: env)
    }

    func callWithArguments(_ closure: ClosureValue, args: CallArguments, node: Syntax?) throws -> RuntimeValue {
        let env = Environment(parent: closure.captured)
        try bindParameters(of: closure, to: args, into: env, node: node)
        let result = try executeBlock(closure.body, in: env)
        switch result {
        case .normal(let value), .returnValue(let value):
            return value
        case .breakLoop, .continueLoop:
            throw RuntimeError(message: "break/continue escaped a function body")
        }
    }

    /// Positional binding: labels are not checked against parameter names (v1
    /// divergence). No-parameter closures get `$0`, `$1`, … shorthand bindings.
    func bindParameters(of closure: ClosureValue, to args: CallArguments, into env: Environment, node: Syntax?) throws {
        if closure.parameters.isEmpty {
            for (index, argument) in args.arguments.enumerated() {
                env.define("$\(index)", argument.value)
            }
            return
        }
        for (index, parameter) in closure.parameters.enumerated() {
            if index < args.arguments.count {
                env.define(parameter.name, args.arguments[index].value)
            } else if let defaultValue = parameter.defaultValue {
                env.define(parameter.name, try evaluate(defaultValue, in: closure.captured))
            } else if let node {
                throw error(node, "missing argument for parameter '\(parameter.name)'")
            } else {
                throw RuntimeError(message: "missing argument for parameter '\(parameter.name)'")
            }
        }
    }

    // MARK: - Operators & assignment

    func evaluateInfix(_ infix: InfixOperatorExprSyntax, in env: Environment) throws -> RuntimeValue {
        if infix.operator.is(AssignmentExprSyntax.self) {
            let value = try evaluate(infix.rightOperand, in: env)
            let target = try resolveLValue(infix.leftOperand, in: env)
            try relocating(infix) { try target.write(value) }
            return .void
        }
        guard let binOp = infix.operator.as(BinaryOperatorExprSyntax.self) else {
            throw error(infix, "unsupported infix operator")
        }
        let op = binOp.operator.text

        switch op {
        case "&&":
            guard try expectBool(evaluate(infix.leftOperand, in: env), node: infix.leftOperand) else {
                return .native(false)
            }
            return .native(try expectBool(evaluate(infix.rightOperand, in: env), node: infix.rightOperand))
        case "||":
            if try expectBool(evaluate(infix.leftOperand, in: env), node: infix.leftOperand) {
                return .native(true)
            }
            return .native(try expectBool(evaluate(infix.rightOperand, in: env), node: infix.rightOperand))
        case "+=", "-=", "*=", "/=", "%=":
            let target = try resolveLValue(infix.leftOperand, in: env)
            let rhs = try evaluate(infix.rightOperand, in: env)
            try relocating(infix) {
                let combined = try Builtins.binary(String(op.dropLast()), try target.read(), rhs)
                try target.write(combined)
            }
            return .void
        default:
            let lhs = try evaluate(infix.leftOperand, in: env)
            let rhs = try evaluate(infix.rightOperand, in: env)
            return try relocating(infix) { try Builtins.binary(op, lhs, rhs) }
        }
    }

    enum LValue {
        case box(Box)
        case element(Box, Int)

        func read() throws -> RuntimeValue {
            switch self {
            case .box(let box):
                return box.value
            case .element(let box, let index):
                guard let array = box.value.arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                return array[index]
            }
        }

        func write(_ value: RuntimeValue) throws {
            switch self {
            case .box(let box):
                box.value = value
            case .element(let box, let index):
                guard var array = box.value.arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                array[index] = value
                box.value = .native(array)
            }
        }
    }

    func resolveLValue(_ expr: ExprSyntax, in env: Environment) throws -> LValue {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if let box = env.box(for: name) { return .box(box) }
            if let instance = currentSelf(in: env), let box = instance.box(for: name) { return .box(box) }
            throw error(ref, "cannot assign to '\(name)'")
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let baseValue = try evaluate(base, in: env)
            guard case .instance(let instance) = baseValue else {
                throw error(member, "cannot assign to a member of \(baseValue.stringified)")
            }
            let name = member.declName.baseName.text
            guard let box = instance.box(for: name) else {
                throw error(member, "'\(instance.symbol.name)' has no stored property '\(name)'")
            }
            return .box(box)
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            let base = try resolveLValue(subscriptCall.calledExpression, in: env)
            guard case .box(let box) = base else {
                throw error(subscriptCall, "nested subscript assignment isn't supported")
            }
            guard let indexExpr = subscriptCall.arguments.first?.expression,
                  let index = try evaluate(indexExpr, in: env).intValue else {
                throw error(subscriptCall, "subscript assignment requires an Int index")
            }
            return .element(box, index)
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return try resolveLValue(only.expression, in: env)
        }
        throw error(expr, "expression is not assignable")
    }

    // MARK: - Literals & helpers

    private func integerValue(of lit: IntegerLiteralExprSyntax) throws -> Int {
        let text = lit.literal.text.filter { $0 != "_" }
        let value: Int?
        if text.hasPrefix("0x") { value = Int(text.dropFirst(2), radix: 16) }
        else if text.hasPrefix("0b") { value = Int(text.dropFirst(2), radix: 2) }
        else if text.hasPrefix("0o") { value = Int(text.dropFirst(2), radix: 8) }
        else { value = Int(text) }
        guard let value else { throw error(lit, "invalid integer literal") }
        return value
    }

    func stringLiteral(_ lit: StringLiteralExprSyntax, in env: Environment) throws -> String {
        if let simple = lit.representedLiteralValue { return simple }
        var out = ""
        for segment in lit.segments {
            switch segment {
            case .stringSegment(let s):
                out += unescape(s.content.text)
            case .expressionSegment(let e):
                for labeled in e.expressions {
                    out += try evaluate(labeled.expression, in: env).stringified
                }
            }
        }
        return out
    }

    private func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\", let next = iterator.next() else {
                out.append(ch)
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"": out.append("\"")
            case "'": out.append("'")
            case "\\": out.append("\\")
            default:
                out.append(ch)
                out.append(next)
            }
        }
        return out
    }

    private func evaluateSubscript(_ call: SubscriptCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        let base = try evaluate(call.calledExpression, in: env)
        guard let indexExpr = call.arguments.first?.expression else {
            throw error(call, "missing subscript index")
        }
        let index = try evaluate(indexExpr, in: env)
        if let array = base.arrayValue {
            guard let i = index.intValue, array.indices.contains(i) else {
                throw error(call, "array index out of range")
            }
            return array[i]
        }
        throw error(call, "subscripting is only supported on arrays")
    }

    func expectBool(_ value: RuntimeValue, node: some SyntaxProtocol) throws -> Bool {
        guard let b = value.boolValue else {
            throw error(node, "expected a Bool, got \(value.stringified)")
        }
        return b
    }

    /// Run a Builtins call, upgrading its unlocated `EvalMessage` to a located error.
    func relocating<T>(_ node: some SyntaxProtocol, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let message as EvalMessage {
            throw error(node, message.text)
        }
    }
}
