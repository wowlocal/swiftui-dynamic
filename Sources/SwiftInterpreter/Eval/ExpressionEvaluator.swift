import Foundation
import SwiftSyntax

/// Expression evaluation: the big dispatch over folded `ExprSyntax`.
extension Interpreter {
    func evaluate(_ expr: ExprSyntax, in env: Environment) throws -> RuntimeValue {
        try tick(expr)
        // Native-stack guard for resolution CYCLES that never pass
        // callWithArguments (lazy-global force loops, member-dispatch
        // cycles). A fixed nesting count can't fit both TCA's legitimate
        // depth and small thread stacks, so probe the real bounds.
        evaluationDepth += 1
        defer { evaluationDepth -= 1 }

        let stackBounds: EvaluationStackBounds
        if let cached = evaluationStackBounds {
            stackBounds = cached
        } else {
            let thread = pthread_self()
            let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
            let size = UInt(pthread_get_stacksize_np(thread))
            let bounds = EvaluationStackBounds(
                lowerBound: top - size,
                size: size,
                // Desktop threads keep the historical 1.5 MB reserve. Small
                // stacks use a proportional reserve with a 32 KB floor.
                safetyHeadroom: size >= 4_194_304
                    ? UInt(1_572_864)
                    : max(UInt(32_768), size / 16))
            evaluationStackBounds = bounds
            stackBounds = bounds
        }
#if os(iOS)
        // SwiftInterpreter is optimized in iOS Debug builds as well as
        // Release, keeping the largest evaluator frames around 2 KB. Four
        // entries remain comfortably inside the 64 KB reserve on a 1 MB
        // main-thread stack while removing most pointer probes from the path.
        let shouldProbeNativeStack = evaluationDepth == 1 || evaluationDepth & 3 == 0
#else
        // Large desktop stacks have ample reserve. A caller-supplied small
        // thread may still be running -Onone, whose dispatch frames are much
        // larger, so probe every entry there.
        let shouldProbeNativeStack = evaluationDepth == 1 || stackBounds.size < 4_194_304
            || evaluationDepth & 15 == 0
#endif
        if shouldProbeNativeStack {
            var probe: UInt8 = 0
            let current = withUnsafePointer(to: &probe) { UInt(bitPattern: $0) }
            if current > stackBounds.lowerBound,
               current - stackBounds.lowerBound < stackBounds.safetyHeadroom {
                if Interpreter.traceStateCells {
                    var counts: [String: Int] = [:]
                    for name in callStackNames { counts[name, default: 0] += 1 }
                    let hot = counts.sorted { $0.value > $1.value }.prefix(8)
                        .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                    let remaining = current - stackBounds.lowerBound
                    FileHandle.standardError.write(Data("   ✖ stack trip; size=\(stackBounds.size) remaining=\(remaining) reserve=\(stackBounds.safetyHeadroom); hot frames: \(hot)\n   ✖ head: \(callStackNames.prefix(6).joined(separator: " → "))\n".utf8))
                }
                let located = error(expr, "evaluation nesting exceeded (possible initialization cycle)")
                throw RuntimeError(
                    message: located.message, line: located.line, column: located.column, fatal: true)
            }
        }
        guard evaluationDepth < 20_000 else {
            if Interpreter.traceStateCells {
                var counts: [String: Int] = [:]
                for name in callStackNames { counts[name, default: 0] += 1 }
                let hot = counts.sorted { $0.value > $1.value }.prefix(8)
                    .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                FileHandle.standardError.write(Data("   ✖ nesting trip; hot frames: \(hot)\n   ✖ tail: \(callStackNames.suffix(12).joined(separator: " → "))\n".utf8))
            }
            let located = error(expr, "evaluation nesting exceeded (possible initialization cycle)")
            throw RuntimeError(
                message: located.message, line: located.line, column: located.column, fatal: true)
        }

        // Single jump on the node kind — this dispatch runs once per
        // evaluated node, so a ~25-deep `as()` chain was pure overhead.
        switch expr.kind {
        case .integerLiteralExpr:
            return .native(try integerValue(of: expr.cast(IntegerLiteralExprSyntax.self)))
        case .floatLiteralExpr:
            let lit = expr.cast(FloatLiteralExprSyntax.self)
            guard let d = Double(lit.literal.text.filter { $0 != "_" }) else {
                throw error(lit, "invalid float literal")
            }
            return .native(d)
        case .booleanLiteralExpr:
            return .native(expr.cast(BooleanLiteralExprSyntax.self).literal.text == "true")
        case .nilLiteralExpr:
            return .nilValue
        case .stringLiteralExpr:
            return .native(try stringLiteral(expr.cast(StringLiteralExprSyntax.self), in: env))
        case .arrayExpr:
            let array = expr.cast(ArrayExprSyntax.self)
            return .native(try array.elements.map { try evaluate($0.expression, in: env) })
        case .dictionaryExpr:
            let dict = expr.cast(DictionaryExprSyntax.self)
            var value = DictValue()
            if case .elements(let elements) = dict.content {
                for element in elements {
                    try relocating(element) {
                        try value.setLiteralEntry(
                            try evaluate(element.key, in: env),
                            to: try evaluate(element.value, in: env))
                    }
                }
            }
            return .native(value)
        case .declReferenceExpr:
            let ref = expr.cast(DeclReferenceExprSyntax.self)
            return try resolveIdentifier(ref.baseName.text, in: env, node: ref)
        case .memberAccessExpr:
            let member = expr.cast(MemberAccessExprSyntax.self)
            guard let base = member.base else {
                return .implicitMember(member.declName.baseName.text)
            }
            let baseValue = try evaluate(base, in: env)
            return try accessMember(
                member.declName.baseName.text, on: baseValue, node: member, env: env)
        case .functionCallExpr:
            return try evaluateCall(expr.cast(FunctionCallExprSyntax.self), in: env)
        case .closureExpr:
            return .closure(try makeClosure(expr.cast(ClosureExprSyntax.self), in: env))
        case .infixOperatorExpr:
            return try evaluateInfix(expr.cast(InfixOperatorExprSyntax.self), in: env)
        case .prefixOperatorExpr:
            let prefix = expr.cast(PrefixOperatorExprSyntax.self)
            if prefix.operator.text == "..<" || prefix.operator.text == "..." {
                let bound = try evaluate(prefix.expression, in: env)
                return .native(RuntimeRangeValue(
                    upperBound: bound,
                    includesUpperBound: prefix.operator.text == "..."))
            }
            if prefix.operator.text == "/",
               globals.lookup(prefix.operator.text) == nil {
                // The CasePaths case-path operator: `/AppAction.milestone`.
                // Resolve the case reference so extract/embed are REAL for
                // interpreted enums; unknown shapes stay textual markers.
                var enumSymbol: EnumSymbol?
                var caseName: String?
                if let member = prefix.expression.as(MemberAccessExprSyntax.self),
                   let baseExpr = member.base,
                   case .enumType(let symbol)? = try? evaluate(baseExpr, in: env) {
                    enumSymbol = symbol
                    caseName = member.declName.baseName.text
                }
                return .native(CasePathMarker(
                    path: prefix.expression.trimmedDescription,
                    enumSymbol: enumSymbol, caseName: caseName))
            }
            let operand = try evaluate(prefix.expression, in: env)
            do {
                return try relocating(prefix) { try Builtins.prefix(prefix.operator.text, operand) }
            } catch let builtinError as RuntimeError where !builtinError.fatal {
                // User-defined prefix operators (`prefix func √`).
                if case .closure(let closure)? = globals.lookup(prefix.operator.text) {
                    return try callWithArguments(
                        closure,
                        args: CallArguments(arguments: [.init(label: nil, value: operand)]),
                        node: nil)
                }
                throw builtinError
            }
        case .postfixOperatorExpr:
            let postfix = expr.cast(PostfixOperatorExprSyntax.self)
            if postfix.operator.text == "..." {
                let bound = try evaluate(postfix.expression, in: env)
                return .native(RuntimeRangeValue(lowerBound: bound))
            }
            // User-defined postfix operators (`postfix func >*` — 2048's
            // AnyView-erasure operator).
            let operand = try evaluate(postfix.expression, in: env)
            if case .closure(let closure)? = globals.lookup(postfix.operator.text) {
                return try callWithArguments(
                    closure,
                    args: CallArguments(arguments: [.init(label: nil, value: operand)]),
                    node: nil)
            }
            throw error(postfix, "unsupported postfix operator '\(postfix.operator.text)'")
        case .ternaryExpr:
            let ternary = expr.cast(TernaryExprSyntax.self)
            let condition = try expectBool(evaluate(ternary.condition, in: env), node: ternary.condition)
            return try evaluate(condition ? ternary.thenExpression : ternary.elseExpression, in: env)
        case .tupleExpr:
            let tuple = expr.cast(TupleExprSyntax.self)
            if tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil {
                return try evaluate(only.expression, in: env)
            }
            let labels = tuple.elements.map { $0.label?.text }
            let values = try tuple.elements.map { try evaluate($0.expression, in: env) }
            return .native(TupleValue(labels: labels, values: values))
        case .subscriptCallExpr:
            return try evaluateSubscript(expr.cast(SubscriptCallExprSyntax.self), in: env)
        case .forceUnwrapExpr:
            let forceUnwrap = expr.cast(ForceUnwrapExprSyntax.self)
            let value = try evaluate(forceUnwrap.expression, in: env)
            guard let unwrapped = value.unwrappedOptionalOrSelf else {
                throw error(forceUnwrap, "unexpectedly found nil while force-unwrapping")
            }
            return unwrapped
        case .optionalChainingExpr:
            // Member/call/subscript on nil propagates nil (see accessMember/invoke).
            return try evaluate(expr.cast(OptionalChainingExprSyntax.self).expression, in: env)
        case .tryExpr:
            let tryExpr = expr.cast(TryExprSyntax.self)
            if tryExpr.questionOrExclamationMark?.text == "?" {
                do {
                    return try evaluate(tryExpr.expression, in: env)
                        .liftedToOptional()
                } catch is InterpretedThrow {
                    return .none()
                } catch let hostError as RuntimeError where !hostError.fatal {
                    return .none()
                } catch {
                    // `try?` catches arbitrary Error values raised by a host
                    // gateway too. Fatal RuntimeErrors were deliberately not
                    // matched above and continue to escape.
                    if let runtimeError = error as? RuntimeError, runtimeError.fatal {
                        throw runtimeError
                    }
                    return .none()
                }
            }
            return try evaluate(tryExpr.expression, in: env) // try / try!
        case .awaitExpr:
            // Synchronous stand-in: async work evaluates inline (documented).
            return try evaluate(expr.cast(AwaitExprSyntax.self).expression, in: env)
        case .keyPathExpr:
            let keyPath = expr.cast(KeyPathExprSyntax.self)
            let components = keyPath.components.map {
                $0.trimmedDescription.hasPrefix(".")
                    ? String($0.trimmedDescription.dropFirst())
                    : $0.trimmedDescription
            }
            return .native(KeyPathStub(components: components))
        case .superExpr:
            if case .instance(let instance)? = env.lookup("self") {
                return .native(SuperReference(instance: instance))
            }
            // STATIC contexts (`static func fetchRequest() { super
            // .fetchRequest() }` on an NSManagedObject subclass): the host
            // superclass's statics absorb — a type marker carries the name.
            if case .type(let symbol)? = env.lookup("self"),
               let superName = symbol.superclassName {
                if case .type(let parent)? = globals.lookup(superName) {
                    return .type(parent)
                }
                return .native(HostTypeMarker(name: superName))
            }
            throw error(expr, "'super' can only be used inside a class body")
        case .inOutExpr:
            let inout_ = expr.cast(InOutExprSyntax.self)
            // `&value` — capture the lvalue so user `inout` parameters can
            // write back; non-closure consumers unwrap to the current value.
            if let target = try? resolveLValue(inout_.expression, in: env) {
                if case .box(let box) = target {
                    return .native(InoutSlot(box: box, target: nil, current: box.value))
                }
                return .native(InoutSlot(box: nil, target: target, current: try target.read(self)))
            }
            return try evaluate(inout_.expression, in: env)
        case .macroExpansionExpr:
            // Registered macros (#expect/#require) execute; the rest stay
            // inert markers (`#selector(...)`, `#Predicate {...}`).
            let macro = expr.cast(MacroExpansionExprSyntax.self)
            if let result = try invokeRegisteredMacro(
                named: macro.macroName.text, arguments: macro.arguments,
                trailingClosure: macro.trailingClosure,
                additionalTrailingClosures: macro.additionalTrailingClosures,
                genericArguments: macro.genericArgumentClause?.arguments
                    .map { $0.argument.trimmedDescription }.joined(separator: ", "),
                node: macro, in: env) {
                return result
            }
            return .native(HostTypeMarker(name: "#\(macro.macroName.text)"))
        case .isExpr:
            // `value is Type` — checkable shapes really check (primitives,
            // interpreted symbols, host type names); unknowables read FALSE
            // (fresh state: nothing persisted IS anything yet).
            let isExpr = expr.cast(IsExprSyntax.self)
            let subject = try evaluate(isExpr.expression, in: env)
            return .native(valueIsType(subject, isExpr.type.trimmedDescription))
        case .asExpr:
            let asExpr = expr.cast(AsExprSyntax.self)
            // Dynamic casts: give the target type a chance to resolve markers,
            // bridge numerics, and otherwise pass the value through
            // (optimistic `as?` — documented divergence).
            let value = try evaluate(asExpr.expression, in: env)
            if asExpr.questionOrExclamationMark?.text == "?", value.isNil {
                return .none(wrappedTypeName: asExpr.type.trimmedDescription)
            }
            var typeName = asExpr.type.trimmedDescription
            if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }
            // A DEFINITE mismatch is nil when both sides are declared in
            // this merge (`action as? AsyncAction` over a plain Action —
            // the SwiftUIFlux dispatch genre); host values and unknown
            // types keep the optimistic pass-through divergence.
            if asExpr.questionOrExclamationMark?.text == "?" {
                let checkable: Bool
                switch value {
                case .instance, .enumCase: checkable = true
                default: checkable = false
                }
                let declaredTarget = typeValue(named: typeName) != nil
                    || protocolInheritance[typeName] != nil
                if checkable, declaredTarget, !valueIsType(value, typeName) {
                    return .none(wrappedTypeName: typeName)
                }
            }
            switch typeName {
            case "Double", "CGFloat", "TimeInterval":
                if let d = value.doubleValue {
                    let converted = RuntimeValue.native(d)
                    return asExpr.questionOrExclamationMark?.text == "?"
                        ? converted.liftedToOptional(wrappedTypeName: typeName)
                        : converted
                }
            case "Int":
                if let d = value.doubleValue {
                    let converted = RuntimeValue.native(Int(d))
                    return asExpr.questionOrExclamationMark?.text == "?"
                        ? converted.liftedToOptional(wrappedTypeName: typeName)
                        : converted
                }
            default:
                break
            }
            let casted = try resolveAnnotated(value, typeName: typeName)
            if asExpr.questionOrExclamationMark?.text == "?" {
                return casted.liftedToOptional(wrappedTypeName: typeName)
            }
            return casted
        case .ifExpr:
            let ifExpr = expr.cast(IfExprSyntax.self)
            if case .normal(let value) = try executeIf(ifExpr, in: env) { return value }
            throw error(ifExpr, "control flow can't escape an if-expression")
        case .switchExpr:
            let switchExpr = expr.cast(SwitchExprSyntax.self)
            if case .normal(let value) = try executeSwitch(switchExpr, in: env) { return value }
            throw error(switchExpr, "control flow can't escape a switch-expression")
        case .postfixIfConfigExpr:
            // `view \n #if os(iOS) \n .modifier() \n #endif` — apply the
            // active clause's postfix chain to the base (inactive: base).
            let postfixIf = expr.cast(PostfixIfConfigExprSyntax.self)
            let baseValue = try postfixIf.base.map { try evaluate($0, in: env) } ?? .void
            guard let clause = activeIfConfigClause(postfixIf.config),
                  case .postfixExpression(let postfix)? = clause.elements else {
                return baseValue
            }
            let child = Environment(parent: env)
            child.define("__postfixBase", baseValue)
            return try evaluate(graftPostfixBase(postfix, name: "__postfixBase"), in: child)
        case .genericSpecializationExpr:
            // `FetchDescriptor<DBModel.Country>()` — HOST constructors get
            // the specialization as a hidden argument, so type-carrying
            // boxes (fetch descriptors) know their model type.
            if let spec = expr.as(GenericSpecializationExprSyntax.self) {
                let resolved = try evaluate(spec.expression, in: env)
                if case .hostFunction(let ctor) = resolved {
                    let genericText = spec.genericArgumentClause.arguments
                        .map { $0.argument.trimmedDescription }
                        .joined(separator: ", ")
                    return .hostFunction(HostFunction(
                        name: ctor.name,
                        invoke: { args, ctx in
                            var enriched = args.arguments
                            enriched.append(.init(
                                label: "__genericArguments", value: .native(genericText)))
                            return try ctor.invoke(CallArguments(arguments: enriched), ctx)
                        },
                        asyncInvoke: { args, ctx in
                            var enriched = args.arguments
                            enriched.append(.init(
                                label: "__genericArguments", value: .native(genericText)))
                            return try await ctor.invokeSuspending(
                                CallArguments(arguments: enriched), ctx)
                        }
                    ))
                }
                return resolved
            }
            // Type arguments are annotations we don't check —
            // `Binding<Int?>(get:set:)` evaluates as `Binding(get:set:)`.
            return try evaluate(expr.cast(GenericSpecializationExprSyntax.self).expression, in: env)
        case .discardAssignmentExpr:
            return .void // `_` in expression position — a write-only slot
        case .sequenceExpr:
            throw error(expr, "internal error: unfolded operator sequence")
        default:
            throw error(expr, "unsupported expression (\(expr.kind))")
        }
    }

    /// Grafts a name reference onto the missing root base of a postfix
    /// chain from `#if`-postfix clauses (`.padding().background(...)`).
    private func graftPostfixBase(_ expr: ExprSyntax, name: String) -> ExprSyntax {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            if let base = member.base {
                return ExprSyntax(member.with(\.base, graftPostfixBase(base, name: name)))
            }
            return ExprSyntax(member.with(
                \.base, ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(name)))))
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return ExprSyntax(call.with(
                \.calledExpression, graftPostfixBase(call.calledExpression, name: name)))
        }
        return expr
    }
}
