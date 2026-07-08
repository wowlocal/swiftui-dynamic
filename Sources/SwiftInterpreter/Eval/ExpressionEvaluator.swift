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
        if let dict = expr.as(DictionaryExprSyntax.self) {
            let value = DictValue()
            if case .elements(let elements) = dict.content {
                for element in elements {
                    try relocating(element) {
                        try value.update(try evaluate(element.key, in: env), to: try evaluate(element.value, in: env))
                    }
                }
            }
            return .native(value)
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
            if tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil {
                return try evaluate(only.expression, in: env)
            }
            let labels = tuple.elements.map { $0.label?.text }
            let values = try tuple.elements.map { try evaluate($0.expression, in: env) }
            return .native(TupleValue(labels: labels, values: values))
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            return try evaluateSubscript(subscriptCall, in: env)
        }
        if let forceUnwrap = expr.as(ForceUnwrapExprSyntax.self) {
            let value = try evaluate(forceUnwrap.expression, in: env)
            guard !value.isNil else {
                throw error(forceUnwrap, "unexpectedly found nil while force-unwrapping")
            }
            return value
        }
        if let chaining = expr.as(OptionalChainingExprSyntax.self) {
            // Member/call/subscript on nil propagates nil (see accessMember/invoke).
            return try evaluate(chaining.expression, in: env)
        }
        if expr.is(KeyPathExprSyntax.self) {
            return .native(KeyPathStub())
        }
        if let ifExpr = expr.as(IfExprSyntax.self) {
            if case .normal(let value) = try executeIf(ifExpr, in: env) { return value }
            throw error(ifExpr, "control flow can't escape an if-expression")
        }
        if let switchExpr = expr.as(SwitchExprSyntax.self) {
            if case .normal(let value) = try executeSwitch(switchExpr, in: env) { return value }
            throw error(switchExpr, "control flow can't escape a switch-expression")
        }
        if expr.is(SequenceExprSyntax.self) {
            throw error(expr, "internal error: unfolded operator sequence")
        }
        throw error(expr, "unsupported expression (\(expr.kind))")
    }

    // MARK: - Identifiers & members

    func resolveIdentifier(_ name: String, in env: Environment, node: some SyntaxProtocol) throws -> RuntimeValue {
        if let value = env.lookup(name) { return value }
        // `$count` — projected value of an @State or @Binding property.
        // (`$0`-style closure shorthands were already bound in the environment.)
        if name.hasPrefix("$"), name.count > 1, !name.dropFirst().allSatisfy(\.isNumber) {
            let propertyName = String(name.dropFirst())
            guard case .instance(let instance)? = env.lookup("self") else {
                throw error(node, "'\(name)' can only be used inside a View body")
            }
            guard let box = instance.projectedBox(for: propertyName) else {
                throw error(node, "'\(name)' requires an @State or @Binding property named '\(propertyName)'")
            }
            return .native(BindingStub(box: box))
        }
        if let selfValue = env.lookup("self"),
           let value = try selfMember(name, on: selfValue) {
            return value
        }
        if let ctor = registry?.constructor(named: name) {
            return .hostFunction(ctor)
        }
        throw error(node, "unresolved identifier '\(name)'")
    }

    /// Implicit-self member resolution (works for struct instances and enum values).
    private func selfMember(_ name: String, on selfValue: RuntimeValue) throws -> RuntimeValue? {
        switch selfValue {
        case .instance(let instance):
            return try instanceMember(name, on: instance)
        case .enumCase(let value):
            return try enumCaseMember(name, on: value)
        default:
            return nil
        }
    }

    /// Property → method → computed property, or nil if the name is unknown.
    func instanceMember(_ name: String, on instance: Instance) throws -> RuntimeValue? {
        if let box = instance.box(for: name) { return box.value }
        if let method = instance.symbol.methods[name] {
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.instance(instance))))
        }
        if let computed = instance.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
        }
        return nil
    }

    private func enumCaseMember(_ name: String, on value: EnumCaseValue) throws -> RuntimeValue? {
        if name == "rawValue" { return value.rawValue }
        if let method = value.symbol.methods[name] {
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumCase(value))))
        }
        if let computed = value.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .enumCase(value), name: name)
        }
        return nil
    }

    func evaluateComputed(_ computed: ComputedProperty, selfValue: RuntimeValue, name: String) throws -> RuntimeValue {
        let env = selfEnvironment(selfValue)
        if computed.isBuilder {
            let views = try collectBuilderViews(computed.accessor, in: env)
            return try groupViews(views)
        }
        let result = try executeBlock(computed.accessor, in: env)
        switch result {
        case .normal(let value), .returnValue(let value): return value
        default: throw RuntimeError(message: "control flow escaped computed property '\(name)'")
        }
    }

    func groupViews(_ views: [RuntimeValue]) throws -> RuntimeValue {
        if views.count == 1 { return views[0] }
        guard let registry else {
            throw RuntimeError(message: "no host registry configured")
        }
        return try registry.makeGroup(views)
    }

    func accessMember(_ name: String, on baseValue: RuntimeValue, node: some SyntaxProtocol, env: Environment) throws -> RuntimeValue {
        switch baseValue {
        case .nilValue:
            // Optional chaining: member access on nil is nil.
            return .nilValue

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

        case .enumCase(let value):
            if let member = try enumCaseMember(name, on: value) { return member }
            throw error(node, "'\(value.symbol.name).\(value.name)' has no member '\(name)'")

        case .enumType(let symbol):
            if let caseInfo = symbol.caseInfo(named: name) {
                if caseInfo.hasAssociatedValues {
                    return .hostFunction(HostFunction(name: name) { args, _ in
                        .enumCase(EnumCaseValue(symbol: symbol, name: name, associated: args.arguments.map(\.value)))
                    })
                }
                return .enumCase(EnumCaseValue(symbol: symbol, name: name))
            }
            if name == "allCases" {
                let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                    RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
                }
                return .native(all)
            }
            if let value = try staticMember(name, properties: symbol.staticProperties, methods: symbol.staticMethods, cache: &symbol.staticCache) {
                return value
            }
            throw error(node, "'\(symbol.name)' has no case or static member '\(name)'")

        case .type(let symbol):
            if let value = try staticMember(name, properties: symbol.staticProperties, methods: symbol.staticMethods, cache: &symbol.staticCache) {
                return value
            }
            throw error(node, "'\(symbol.name)' has no static member '\(name)'")

        case .implicitMember(let baseName):
            // `.blue.opacity(0.2)` / `.blue.gradient` — keep the chain opaque
            // for gateways. Calling the result refines the arguments.
            return .native(ChainedImplicitCall(baseName: baseName, member: name, arguments: CallArguments()))

        case .native(let any):
            if let tuple = any as? TupleValue, let value = tuple.value(for: name) {
                return value
            }
            if let value = try nativeMember(name, on: any) {
                return value
            }
            if let registry, registry.isViewValue(baseValue), let modifier = registry.modifier(named: name) {
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(baseValue, args, ctx)
                })
            }
            throw error(node, "unsupported member '\(name)' on \(type(of: any))")

        default:
            throw error(node, "cannot access member '\(name)' on \(baseValue.stringified)")
        }
    }

    private func staticMember(
        _ name: String,
        properties: [String: ExprSyntax],
        methods: [String: FunctionDeclSyntax],
        cache: inout [String: RuntimeValue]
    ) throws -> RuntimeValue? {
        if let cached = cache[name] { return cached }
        if let initializer = properties[name] {
            let value = try evaluate(initializer, in: globals)
            cache[name] = value
            return value
        }
        if let method = methods[name], let body = method.body {
            return .closure(makeFunctionClosure(method, body: body, captured: globals))
        }
        return nil
    }

    // MARK: - Calls

    func evaluateCall(_ call: FunctionCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        // `.system(size: 40)` — implicit member call, resolved later by a gateway.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil {
            let args = try collectArguments(of: call, in: env)
            return .native(ImplicitMemberCall(name: member.declName.baseName.text, arguments: args))
        }
        // Methods that mutate collections in place, and property/method pairs
        // like `first` / `first(where:)`, need the base handled specially.
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
            if let result = try specialMemberCall(member.declName.baseName.text, base: base, call: call, in: env) {
                return result
            }
        }
        let callee = try evaluate(call.calledExpression, in: env)
        let args = try collectArguments(of: call, in: env)
        return try invoke(callee, with: args, node: call)
    }

    /// Mutating collection methods (`items.append(x)`) resolve the base as an
    /// lvalue; `first(where:)`/`last(where:)` collide with the same-named
    /// properties. Returns nil to fall through to normal dispatch.
    private func specialMemberCall(
        _ name: String,
        base: ExprSyntax,
        call: FunctionCallExprSyntax,
        in env: Environment
    ) throws -> RuntimeValue? {
        let mutating = ["append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "sort"]
        if mutating.contains(name),
           let target = try? resolveLValue(base, in: env),
           var array = try target.read().arrayValue {
            let args = try collectArguments(of: call, in: env)
            switch name {
            case "append":
                guard let value = args.positional(0) else { throw error(call, "append needs a value") }
                array.append(value)
            case "insert":
                guard let value = args.positional(0), let index = args.labeled("at")?.intValue,
                      index >= 0, index <= array.count else {
                    throw error(call, "insert needs a value and a valid at: index")
                }
                array.insert(value, at: index)
            case "remove":
                guard let index = args.labeled("at")?.intValue, array.indices.contains(index) else {
                    throw error(call, "remove(at:) index out of range")
                }
                let removed = array.remove(at: index)
                try relocating(call) { try target.write(.native(array)) }
                return removed
            case "removeAll":
                if let closure = args.closure(labeled: "where") {
                    var kept: [RuntimeValue] = []
                    for element in array where try callClosure(closure, arguments: [element]).boolValue != true {
                        kept.append(element)
                    }
                    array = kept
                } else {
                    array = []
                }
            case "removeFirst":
                guard !array.isEmpty else { throw error(call, "removeFirst on an empty array") }
                let removed = array.removeFirst()
                try relocating(call) { try target.write(.native(array)) }
                return removed
            case "removeLast":
                guard !array.isEmpty else { throw error(call, "removeLast on an empty array") }
                let removed = array.removeLast()
                try relocating(call) { try target.write(.native(array)) }
                return removed
            case "sort":
                var failure: Error?
                array.sort { a, b in
                    if failure != nil { return false }
                    do { return try Builtins.binary("<", a, b).boolValue == true }
                    catch { failure = error; return false }
                }
                if let failure { throw failure }
            default:
                return nil
            }
            try relocating(call) { try target.write(.native(array)) }
            return .void
        }

        if name == "first" || name == "last" {
            let baseValue = try evaluate(base, in: env)
            let array = baseValue.arrayValue ?? baseValue.rangeValue.map { range in range.map { RuntimeValue.native($0) } }
            if let array {
                let args = try collectArguments(of: call, in: env)
                if let closure = args.closure(labeled: "where") ?? args.unlabeledClosures.first {
                    let ordered = name == "last" ? Array(array.reversed()) : array
                    for element in ordered where try callClosure(closure, arguments: [element]).boolValue == true {
                        return element
                    }
                    return .nilValue
                }
            }
        }
        return nil
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
        case .nilValue:
            return .nilValue // optional chaining through a nil method
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
        case .native(let any) where any is ChainedImplicitCall:
            let chained = any as! ChainedImplicitCall
            return .native(ChainedImplicitCall(baseName: chained.baseName, member: chained.member, arguments: args))
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
        if closure.isBuilder {
            return try groupViews(try collectBuilderViews(closure.body, in: env))
        }
        let result = try executeBlock(closure.body, in: env)
        switch result {
        case .normal(let value), .returnValue(let value):
            return resolveAnnotated(value, annotation: closure.returnType)
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
                env.define(parameter.name, resolveAnnotated(args.arguments[index].value, annotation: parameter.typeAnnotation))
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
        case "??":
            let lhs = try evaluate(infix.leftOperand, in: env)
            return lhs.isNil ? try evaluate(infix.rightOperand, in: env) : lhs
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
        case instanceProperty(Instance, String)
        case element(Box, Int)
        case dictElement(DictValue, RuntimeValue)

        func read() throws -> RuntimeValue {
            switch self {
            case .box(let box):
                return box.value
            case .instanceProperty(let instance, let name):
                guard let box = instance.box(for: name) else {
                    throw EvalMessage(text: "'\(instance.symbol.name)' has no stored property '\(name)'")
                }
                return box.value
            case .element(let box, let index):
                guard let array = box.value.arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                return array[index]
            case .dictElement(let dict, let key):
                return try dict.lookup(key)
            }
        }

        func write(_ value: RuntimeValue) throws {
            switch self {
            case .box(let box):
                box.value = value
            case .instanceProperty(let instance, let name):
                // Assigning a $binding into an @Binding property shares the
                // parent's box instead of copying the stub (custom inits).
                if case .native(let any) = value, let stub = any as? BindingStub,
                   instance.symbol.storedProperty(named: name)?.wrapper == .binding {
                    instance.properties[name] = stub.box
                    return
                }
                guard let box = instance.box(for: name) else {
                    throw EvalMessage(text: "'\(instance.symbol.name)' has no stored property '\(name)'")
                }
                box.value = value
            case .element(let box, let index):
                guard var array = box.value.arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                array[index] = value
                box.value = .native(array)
            case .dictElement(let dict, let key):
                try dict.update(key, to: value)
            }
        }
    }

    func resolveLValue(_ expr: ExprSyntax, in env: Environment) throws -> LValue {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if let box = env.box(for: name) { return .box(box) }
            if case .instance(let instance)? = env.lookup("self"), instance.box(for: name) != nil {
                return .instanceProperty(instance, name)
            }
            throw error(ref, "cannot assign to '\(name)'")
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let baseValue = try evaluate(base, in: env)
            guard case .instance(let instance) = baseValue else {
                throw error(member, "cannot assign to a member of \(baseValue.stringified)")
            }
            return .instanceProperty(instance, member.declName.baseName.text)
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            guard let indexExpr = subscriptCall.arguments.first?.expression else {
                throw error(subscriptCall, "missing subscript index")
            }
            let baseValue = try? evaluate(subscriptCall.calledExpression, in: env)
            if let dict = baseValue?.dictValue {
                return .dictElement(dict, try evaluate(indexExpr, in: env))
            }
            let base = try resolveLValue(subscriptCall.calledExpression, in: env)
            guard case .box(let box) = base else {
                throw error(subscriptCall, "nested subscript assignment isn't supported")
            }
            guard let index = try evaluate(indexExpr, in: env).intValue else {
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
        if base.isNil { return .nilValue }
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
        if let dict = base.dictValue {
            return try relocating(call) { try dict.lookup(index) }
        }
        if let range = base.rangeValue, let i = index.intValue {
            let materialized = Array(range)
            guard materialized.indices.contains(i) else { throw error(call, "range index out of range") }
            return .native(materialized[i])
        }
        throw error(call, "subscripting is only supported on arrays and dictionaries")
    }

    func expectBool(_ value: RuntimeValue, node: some SyntaxProtocol) throws -> Bool {
        guard let b = value.boolValue else {
            throw error(node, "expected a Bool, got \(value.stringified)")
        }
        return b
    }

    /// Run a Builtins call, upgrading its unlocated `EvalMessage` to a located error.
    @discardableResult
    func relocating<T>(_ node: some SyntaxProtocol, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let message as EvalMessage {
            throw error(node, message.text)
        }
    }
}
