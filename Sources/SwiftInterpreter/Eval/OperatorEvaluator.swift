import Foundation
import SwiftSyntax

extension Interpreter {
    // MARK: - Operators & assignment

    /// Assignment RHS carries the TARGET property's declared type as the
    /// ambient hint (`statuses = try await client.get()` — return-position
    /// generics bind at the call site, exactly like `let x: [Status] = …`).
    /// Only self-rooted targets are inspected: their annotation is knowable
    /// without evaluating anything.
    func assignmentAnnotationHint(_ target: ExprSyntax, in env: Environment) -> String? {
        var propertyName: String?
        if let ref = target.as(DeclReferenceExprSyntax.self) {
            propertyName = ref.baseName.text
        } else if let member = target.as(MemberAccessExprSyntax.self),
                  member.base == nil
                    || member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            propertyName = member.declName.baseName.text
        }
        guard let propertyName,
              case .instance(let instance)? = env.lookup("self") else { return nil }
        return instance.symbol.storedProperty(named: propertyName)?.typeName
    }

    func evaluateInfix(_ infix: InfixOperatorExprSyntax, in env: Environment) throws -> RuntimeValue {
        if infix.operator.is(AssignmentExprSyntax.self) {
            let hint = assignmentAnnotationHint(infix.leftOperand, in: env)
            let value = try withExpectedAnnotation(hint) { try evaluate(infix.rightOperand, in: env) }
            if infix.leftOperand.is(DiscardAssignmentExprSyntax.self) {
                _ = value // `_ = expr` — evaluate for effect, discard
                return .void
            }
            // Tuple destructuring assignment: `(self.first, self.second,
            // self.third) = (first, second, third)` writes element-wise.
            if let tuple = infix.leftOperand.as(TupleExprSyntax.self), tuple.elements.count > 1 {
                let values: [RuntimeValue]
                if let t = value.tupleValue {
                    values = t.values
                } else if let a = value.arrayValue {
                    values = a
                } else {
                    throw error(infix, "tuple assignment needs a tuple value")
                }
                guard values.count == tuple.elements.count else {
                    throw error(infix, "tuple assignment arity mismatch")
                }
                for (element, elementValue) in zip(tuple.elements, values) {
                    if element.expression.is(DiscardAssignmentExprSyntax.self) { continue }
                    let target = try resolveLValue(
                        element.expression, in: env, access: .writeOnly)
                    try relocating(infix) { try target.write(elementValue, self) }
                }
                return .void
            }
            let target = try resolveLValue(
                infix.leftOperand, in: env, access: .writeOnly)
            try relocating(infix) { try target.write(value, self) }
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
            switch lhs.optionalState {
            case .none:
                return try evaluate(infix.rightOperand, in: env)
            case .some(let wrapped, _):
                return wrapped
            case .notOptional:
                return lhs
            }
        case "+=", "-=", "*=", "/=", "%=", "&+=", "&-=", "&*=",
             "&=", "|=", "^=", "<<=", ">>=":
            let target = try resolveLValue(infix.leftOperand, in: env)
            var rhs = try evaluate(infix.rightOperand, in: env)
            let current = try target.read(self)
            // `date -= .random(in:using:)` — factory markers DRAW here too
            // (the compound path bypasses the infix adoption).
            rhs = try adoptNumericFactoryMarker(rhs, peer: current)
            do {
                let combined = try relocating(infix) {
                    try Builtins.binary(String(op.dropLast()), current, rhs)
                }
                try target.writeOwned(combined, self)
            } catch let builtinError as RuntimeError where !builtinError.fatal {
                // USER-DECLARED operator functions: the whole compound form
                // first (`func +=(lhs: inout [Int: Movie], rhs: [Movie])` —
                // the MovieSwiftUI reducer genre), then a declared combining
                // form of the base operator.
                if case .closure(let fn)? = globals.lookup(op) {
                    let slot = InoutSlot(box: nil, target: target, current: current)
                    _ = try callClosure(fn, arguments: [.native(slot), rhs])
                    return .void
                }
                if case .closure(let fn)? = globals.lookup(String(op.dropLast())) {
                    try target.writeOwned(
                        try callClosure(fn, arguments: [current, rhs]), self)
                    return .void
                }
                throw builtinError
            }
            return .void
        default:
            var lhs = try evaluate(infix.leftOperand, in: env)
            var rhs = try evaluate(infix.rightOperand, in: env)
            if op == "~=" {
                return .native(try matchRuntimePattern(lhs, subject: rhs, env: env, node: infix))
            }
            // Pure numeric pairs skip the marker/registry machinery below —
            // all of it is a no-op for concrete Int/Double operands.
            if let fast = try relocating(infix, { try Builtins.fastNumericBinary(op, lhs, rhs) }) {
                return fast
            }
            // `dragOffset == .zero` / `40 + .statusColumnsSpacing` — an
            // unresolved implicit member adopts the other operand's host
            // type before combining (static constants in user extensions
            // resolve to their real values). Call-shaped markers
            // (.init(…) elementwise arithmetic) only adopt for equality.
            let allowCalls = op == "==" || op == "!="
            lhs = try adoptHostType(of: rhs, for: lhs, allowCalls: allowCalls)
            rhs = try adoptHostType(of: lhs, for: rhs, allowCalls: allowCalls)
            (lhs, rhs) = try contextualizeSetLiteralEquality(
                lhs, rhs, op: op,
                leftIsLiteral: infix.leftOperand.is(ArrayExprSyntax.self),
                rightIsLiteral: infix.rightOperand.is(ArrayExprSyntax.self))
            // A USER-DECLARED `static func ==` on an interpreted type WINS
            // over structural equality — Loadable ignores its cancelBag in
            // its own ==, while payload-wise comparison would not (the
            // clean-architecture LoadableTests genre). `!=` negates it.
            if op == "==" || op == "!=",
               let viaDeclared = try equalsViaDeclaredOperator(lhs, rhs, node: Syntax(infix)) {
                return .bool(op == "==" ? viaDeclared : !viaDeclared)
            }
            // Host-typed operators the core can't know (`Text("a") + Text("b")`).
            if let registry, let combined = registry.combineValues(op, lhs, rhs) {
                return combined
            }
            // Implicit FACTORY markers in numeric-operand position adopt the
            // peer's family before arithmetic (`date -= .random(in: 60..<180,
            // using: &g)` must DRAW, not absorb-to-zero — the seeded stream
            // shifts otherwise). Unresolvable markers pass through unchanged,
            // keeping the absorb doctrine.
            let adoptedLhs = try adoptNumericFactoryMarker(lhs, peer: rhs)
            let adoptedRhs = try adoptNumericFactoryMarker(rhs, peer: adoptedLhs)
            do {
                return try relocating(infix) { try Builtins.binary(op, adoptedLhs, adoptedRhs) }
            } catch let builtinError as RuntimeError where !builtinError.fatal {
                if let viaDeclared = try declaredOperatorValue(
                    op,
                    lhs,
                    rhs,
                    lhsDeclaredTypeName: declaredMemberReceiverTypeName(
                        for: infix.leftOperand, in: env),
                    rhsDeclaredTypeName: declaredMemberReceiverTypeName(
                        for: infix.rightOperand, in: env)) {
                    return viaDeclared
                }
                // User-defined infix operators (`|>` pipe-forward, `~=`
                // overloads) — top-level operator functions. Source
                // declarations dispatch through their overload family so an
                // unrelated same-shaped declaration cannot win merely
                // because it was defined last.
                let operatorArguments = CallArguments(arguments: [
                    .init(label: nil, value: lhs),
                    .init(label: nil, value: rhs),
                ])
                if let overloads = globalFunctionOverloads[op] {
                    let fitting = operatorFunctionsFittingRuntimeTypes(
                        from: overloads, args: operatorArguments)
                    let available = fitting.count > 1
                        ? fitting.filter {
                            !activeFunctionBodies.contains($0.id)
                        }
                        : fitting
                    if let method = available.first,
                       let body = functionMetadata(for: method).body {
                        let closure = makeFunctionClosure(
                            method, body: body, captured: globals)
                        return try callWithArguments(
                            closure, args: operatorArguments, node: nil)
                    }
                } else if case .closure(let closure)? = globals.lookup(op) {
                    return try callWithArguments(
                        closure,
                        args: operatorArguments,
                        node: nil)
                }
                // Ecosystem operators from EXTERNAL modules: `|>` is
                // pipe-forward everywhere it exists (Overture/Point-Free);
                // `>>>`/`<<<` are function composition.
                if op == "|>" {
                    return try invoke(rhs, with: CallArguments(arguments: [
                        .init(label: nil, value: lhs),
                    ]), node: infix)
                }
                if op == "<|" {
                    return try invoke(lhs, with: CallArguments(arguments: [
                        .init(label: nil, value: rhs),
                    ]), node: infix)
                }
                if op == ">>>" || op == "<<<" || op == ">=>" {
                    // `>=>` is Point-Free's Kleisli composition — headlessly
                    // the monadic layer absorbs, so it composes like `>>>`.
                    let first = op == "<<<" ? rhs : lhs
                    let second = op == "<<<" ? lhs : rhs
                    let capturedNode = infix
                    return .hostFunction(HostFunction(name: op) { [weak self] args, _ in
                        guard let self else { throw RuntimeError(message: "interpreter gone") }
                        let x = args.positional(0) ?? .void
                        let mid = try self.invoke(first, with: CallArguments(arguments: [
                            .init(label: nil, value: x),
                        ]), node: capturedNode)
                        return try self.invoke(second, with: CallArguments(arguments: [
                            .init(label: nil, value: mid),
                        ]), node: capturedNode)
                    })
                }
                throw builtinError
            }
        }
    }

    /// Array literals adopt a Set peer's contextual type for equality:
    /// `selection == [sessionID]` is Set-vs-Set in compiled Swift. Named
    /// Array values remain Arrays and are deliberately not coerced.
    func contextualizeSetLiteralEquality(
        _ originalLeft: RuntimeValue, _ originalRight: RuntimeValue,
        op: String, leftIsLiteral: Bool, rightIsLiteral: Bool
    ) throws -> (RuntimeValue, RuntimeValue) {
        guard op == "==" || op == "!=" else {
            return (originalLeft, originalRight)
        }
        var left = originalLeft
        var right = originalRight
        if let set = left.setValue, rightIsLiteral,
           let elements = right.arrayValue {
            right = .native(try makeRuntimeSet(
                elements, elementTypeName: set.elementTypeName))
        } else if let set = right.setValue, leftIsLiteral,
                  let elements = left.arrayValue {
            left = .native(try makeRuntimeSet(
                elements, elementTypeName: set.elementTypeName))
        }
        return (left, right)
    }

    func adoptHostType(of other: RuntimeValue, for value: RuntimeValue, allowCalls: Bool = true) throws -> RuntimeValue {
        let unresolved: Bool
        switch value {
        case .implicitMember:
            unresolved = true
        case .host(let any):
            unresolved = allowCalls && (any is ImplicitMemberCall || any is ChainedImplicitCall)
        default:
            unresolved = false
        }
        guard unresolved, case .host(let otherAny) = other else { return value }
        // Our CGFloat/TimeInterval model IS Double — statics declared on
        // either name apply to Double operands.
        var candidates = [String(describing: type(of: otherAny))]
        if otherAny is Double { candidates += ["CGFloat", "TimeInterval"] }
        for typeName in candidates {
            let resolved = try resolveAnnotated(value, typeName: typeName)
            let stillUnresolved: Bool
            switch resolved {
            case .implicitMember: stillUnresolved = true
            case .nilValue: stillUnresolved = true // a nil never beats the marker
            case .host(let any):
                stillUnresolved = any is ImplicitMemberCall || any is ChainedImplicitCall
            default: stillUnresolved = false
            }
            if !stillUnresolved { return resolved }
        }
        return value
    }

    private func containsOptionalChaining(_ expression: ExprSyntax) -> Bool {
        var pending = [Syntax(expression)]
        while let current = pending.popLast() {
            if current.is(OptionalChainingExprSyntax.self) { return true }
            pending.append(contentsOf: current.children(viewMode: .sourceAccurate))
        }
        return false
    }

    enum LValueAccess {
        case readModify
        case writeOnly
    }

    @MainActor
    enum DictionaryDefault {
        case resolved(RuntimeValue)
        case deferred(ExprSyntax, Environment)

        func value(in interpreter: Interpreter) throws -> RuntimeValue {
            switch self {
            case .resolved(let value):
                return value
            case .deferred(let expression, let environment):
                return try interpreter.evaluate(expression, in: environment)
            }
        }
    }

    @MainActor
    indirect enum LValue {
        case box(Box)
        case instanceProperty(Instance, String)
        /// A stored/computed property on a source struct. Mutation happens on
        /// an independent receiver and writes the whole value back through
        /// its owner, recursively composing through nested members/containers.
        case instanceValueProperty(LValue, StructSymbol, String)
        case hostProperty(Any, String)
        case element(LValue, Int)
        /// Dictionary writes are read-modify-write through their owning
        /// lvalue, preserving value semantics and outer-container write-back.
        case dictElement(
            LValue, RuntimeValue, fallback: DictionaryDefault? = nil)
        /// `trigger.0 = …` / `pair.label = …` — writes mutate the tuple and
        /// re-write the base, so state boxes still notify.
        case tupleElement(LValue, Int)
        /// `matrix[index] = block` — user subscript get/set.
        case instanceSubscript(Instance, CallArguments)
        /// User subscript on a source struct, with the same copy-in/copy-out
        /// ownership as an ordinary value property.
        case instanceValueSubscript(LValue, CallArguments)
        /// `size.width = 300` — value-type member write-through: mutate a
        /// copy via the registry, re-write the base (state boxes notify).
        case hostValueMember(LValue, String)
        /// A generated mutable collection projection owned by native String.
        /// Reads expose the view's elements through the interpreter's array
        /// carrier; writes rebuild the compiled view and copy out the String.
        case nativeWritableStringCollectionView(LValue, String)
        /// `ChatClient.shared = …` — static stored properties (including
        /// host-type extension statics) write to the symbol's static cache.
        case staticProperty(StructSymbol, String)
        /// The same storage edge for enums used as namespaces.
        case enumStaticProperty(EnumSymbol, String)
        /// `values[i] = UInt8(x)` — Data byte write-through: mutate a copy,
        /// re-write the base (value semantics).
        case dataElement(LValue, Int)
        /// `optional! += value` reads one Optional layer and writes the
        /// result through the annotated underlying storage.
        case forceUnwrapped(LValue)

        /// The source annotation at this lvalue, including annotations reached
        /// through nested collection elements and force-unwrapped storage.
        func annotatedTypeName() -> String? {
            switch self {
            case .box(let box):
                return box.declaredTypeName
            case .instanceProperty(let instance, let name):
                return instance.symbol.storedProperty(named: name)?.typeName
            case .instanceValueProperty(_, let symbol, let name):
                return symbol.storedProperty(named: name)?.typeName
            case .staticProperty(let symbol, let name):
                return symbol.staticProperties[name]?.typeName
            case .enumStaticProperty(let symbol, let name):
                return symbol.staticProperties[name]?.typeName
            case .element(let base, _):
                return base.annotatedElementType()
            case .dictElement(let base, _, _):
                return base.annotatedDictionaryTypes()?.value
            case .forceUnwrapped(let base):
                guard let typeName = base.annotatedTypeName() else { return nil }
                return RuntimeOptionalValue.wrappedType(in: typeName) ?? typeName
            default:
                return nil
            }
        }

        /// The element type of an `[X]`- or `Set<X>`-annotated lvalue, if
        /// known. Nested arrays peel one source annotation at a time.
        func annotatedElementType() -> String? {
            guard let raw = annotatedTypeName() else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("["), text.hasSuffix("]"), !text.contains(":") {
                return String(text.dropFirst().dropLast())
            }
            if text.hasPrefix("Set<"), text.hasSuffix(">") {
                return String(text.dropFirst("Set<".count).dropLast())
            }
            return nil
        }

        func annotatedDictionaryTypes() -> (key: String, value: String)? {
            guard let raw = annotatedTypeName() else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
            let parts = SwiftInterpreter.splitTopLevel(
                String(text.dropFirst().dropLast()), separator: ":")
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }

        func read(_ interpreter: Interpreter) throws -> RuntimeValue {
            switch self {
            case .box(let box):
                return try interpreter.force(box)
            case .instanceProperty(let instance, let name):
                try interpreter.requireActorStoredPropertyAccess(
                    instance, property: name)
                if let box = instance.box(for: name) { return try box.load() }
                if let computed = instance.symbol.computedProperties[name] {
                    return try interpreter.evaluateComputed(computed, selfValue: .instance(instance), name: name)
                }
                if let superName = instance.symbol.superclassName,
                   interpreter.interpretedSuperclass(of: instance.symbol) == nil {
                    return .native(ChainedImplicitCall(
                        base: .implicitMember(superName), member: name, arguments: CallArguments()))
                }
                throw EvalMessage(text: "'\(instance.symbol.name)' has no property '\(name)'")
            case .instanceValueProperty(let base, _, let name):
                guard case .instance(let instance) = try base.read(interpreter) else {
                    throw EvalMessage(text: "value-property receiver is not an instance")
                }
                return try LValue.instanceProperty(instance, name).read(interpreter)
            case .hostProperty(let any, let name):
                if let stub = any as? BindingStub, name == "wrappedValue" {
                    return try stub.box.load()
                }
                if let value = try interpreter.readHostMember(name, on: any) { return value }
                if any is InertCallable || any is ImplicitMemberCall || any is ChainedImplicitCall {
                    // Mutating an unknown stub member (`store.products += …`)
                    // reads an unknowable chain — the write absorbs.
                    return .native(ChainedImplicitCall(
                        base: .native(any), member: name, arguments: CallArguments()))
                }
                throw EvalMessage(text: "no readable member '\(name)' on \(type(of: any))")
            case .element(let base, let index):
                guard let array = try base.read(interpreter).arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                return array[index]
            case .dictElement(let base, let key, let fallback):
                let current = try base.read(interpreter)
                guard let dict = current.dictValue else {
                    throw EvalMessage(text: "dictionary lvalue contains \(current.stringified), not a dictionary")
                }
                let found = try dict.value(
                    forKey: key,
                    by: interpreter.collectionStorageValuesAreEqual)
                // `sales[key, default: 0] += v` — missing keys read the
                // default before the mutation, exactly like native.
                if let found { return found }
                if let fallback { return try fallback.value(in: interpreter) }
                return .nilValue
            case .tupleElement(let base, let index):
                guard let tuple = try base.read(interpreter).tupleValue,
                      tuple.values.indices.contains(index) else {
                    throw EvalMessage(text: "tuple element \(index) out of range")
                }
                return tuple.values[index]
            case .instanceSubscript(let instance, let args):
                return try interpreter.callUserSubscriptGetter(on: instance, with: args)
            case .instanceValueSubscript(let base, let args):
                guard case .instance(let instance) = try base.read(interpreter) else {
                    throw EvalMessage(text: "value-subscript receiver is not an instance")
                }
                return try interpreter.callUserSubscriptGetter(on: instance, with: args)
            case .staticProperty(let symbol, let name):
                return try interpreter.staticMember(name, of: symbol) ?? .nilValue
            case .enumStaticProperty(let symbol, let name):
                return try interpreter.staticMember(name, of: symbol) ?? .nilValue
            case .dataElement(let base, let index):
                guard case .host(let any) = try base.read(interpreter), let bytes = any as? Data,
                      index >= 0, index < bytes.count else {
                    throw EvalMessage(text: "Data index \(index) out of range")
                }
                return .native(Int(bytes[bytes.index(bytes.startIndex, offsetBy: index)]))
            case .hostValueMember(let base, let name):
                let baseValue = try base.read(interpreter)
                guard case .host(let any) = baseValue,
                      let member = try interpreter.readHostMember(name, on: any) else {
                    throw EvalMessage(text: "no readable member '\(name)'")
                }
                return member
            case .nativeWritableStringCollectionView(let base, let name):
                guard let owner = try base.read(interpreter).stringValue,
                      let view = GeneratedCollectionDefaultSurface
                        .nativeWritableStringCollectionView(
                            named: name, on: owner) else {
                    throw EvalMessage(
                        text: "no readable generated String view '\(name)'")
                }
                return view
            case .forceUnwrapped(let base):
                guard let value = try base.read(interpreter)
                    .unwrappedOptionalOrSelf else {
                    throw EvalMessage(
                        text: "unexpectedly found nil while force-unwrapping")
                }
                return value
            }
        }

        /// Store an external RHS. Source values copy at the first storage
        /// boundary, matching ordinary Swift assignment.
        func write(_ value: RuntimeValue, _ interpreter: Interpreter) throws {
            try write(value, interpreter, copyingInput: true)
        }

        /// Commit a value already made independent by read-modify-write or a
        /// mutating-method transaction. Outward lvalue layers transfer this
        /// owned value instead of recursively cloning it again.
        func writeOwned(_ value: RuntimeValue, _ interpreter: Interpreter) throws {
            try write(
                value, interpreter, copyingInput: false,
                resolvingAnnotation: true)
        }

        /// Commit a read-modify-write transaction whose changed leaf has
        /// already been resolved against its source annotation. Collection
        /// mutators use this path so appending one element does not re-resolve
        /// every unchanged element on every write.
        func writeCanonicalOwned(
            _ value: RuntimeValue, _ interpreter: Interpreter
        ) throws {
            try write(
                value, interpreter, copyingInput: false,
                resolvingAnnotation: false)
        }

        private func write(
            _ value: RuntimeValue, _ interpreter: Interpreter,
            copyingInput: Bool, resolvingAnnotation: Bool = true
        ) throws {
            @inline(__always) func stored(_ value: RuntimeValue) -> RuntimeValue {
                copyingInput ? value.copiedForValueSemantics() : value
            }
            switch self {
            case .box(let box):
                let resolved = try (resolvingAnnotation ? box.declaredTypeName : nil).map {
                    try interpreter.resolveAnnotated(value, typeName: $0)
                } ?? value
                box.value = stored(resolved)
            case .instanceProperty(let instance, let name):
                try interpreter.requireActorStoredPropertyAccess(
                    instance, property: name)
                if Interpreter.traceStateCells,
                   name == (ProcessInfo.processInfo.environment["INTERP_TRACE_PROP"] ?? "statusesState") {
                    Swift.print("   ✍ \(instance.symbol.name)(\(UInt(bitPattern: ObjectIdentifier(instance).hashValue) % 100000)).\(name) = \(value.stringified.prefix(50))")
                }
                // Assigning a $binding into an @Binding property shares the
                // parent's box instead of copying the stub (custom inits).
                if case .host(let any) = value, let stub = any as? BindingStub,
                   instance.symbol.storedProperty(named: name)?.wrapper == .binding {
                    instance.properties[name] = stub.box
                    return
                }
                if let box = instance.box(for: name) {
                    // Plain assignment adopts the property's annotation
                    // (`self.amount = .random(in:)`, `self.date = .now`).
                    let property = instance.symbol.storedProperty(named: name)
                    // `_fetcher = .init(initialValue: vm)` — the property-
                    // wrapper BACKING spelling: the box takes the WRAPPED
                    // seed, not the `.init` marker (unwrapped BEFORE the
                    // annotation resolves, or a concrete annotation would
                    // eat the marker through its own constructor).
                    var incoming = value
                    if let property,
                       [.state, .stateObject, .observedObject, .binding].contains(property.wrapper),
                       case .host(let any) = incoming,
                       let call = any as? ImplicitMemberCall, call.name == "init",
                       let seed = call.arguments.labeled("initialValue")
                           ?? call.arguments.labeled("wrappedValue")
                           ?? call.arguments.labeled("projectedValue") {
                        incoming = seed
                    }
                    let resolved = resolvingAnnotation
                        ? try interpreter.resolveAnnotated(
                            incoming, typeName: property?.typeName)
                        : incoming
                    let storedValue = stored(resolved)
                    let observerKey = Interpreter.ObserverKey(
                        instance: ObjectIdentifier(instance), property: name)
                    let observed = (property?.willSetBody != nil || property?.didSetBody != nil)
                        && !interpreter.activePropertyObservers.contains(observerKey)
                        && !instance.isInitializing
                        && !interpreter.initializingInstances.contains(ObjectIdentifier(instance))
                    guard observed, let property else {
                        box.value = storedValue
                        return
                    }
                    // willSet(newValue) → write → didSet(oldValue), never
                    // re-entrant on the same property (compiled semantics;
                    // initialization bypasses this funnel entirely).
                    interpreter.activePropertyObservers.insert(observerKey)
                    defer { interpreter.activePropertyObservers.remove(observerKey) }
                    let oldValue = box.value
                    if let willSet = property.willSetBody {
                        let env = interpreter.selfEnvironment(.instance(instance))
                        env.define(property.willSetParameter, storedValue)
                        _ = try interpreter.executeBlock(willSet, in: env)
                    }
                    box.value = storedValue
                    if let didSet = property.didSetBody {
                        let env = interpreter.selfEnvironment(.instance(instance))
                        env.define(property.didSetParameter, oldValue)
                        _ = try interpreter.executeBlock(didSet, in: env)
                    }
                    return
                }
                if let computed = instance.symbol.computedProperties[name] {
                    if let failure =
                        computed.unsupportedCoroutineModifyError {
                        throw failure
                    }
                    guard computed.setter != nil else {
                        if interpreter.assumesCompiledImports {
                            // A get-only assignment can't compile natively —
                            // the setter lives somewhere the merge didn't
                            // capture: the write drops (artifact doctrine).
                            return
                        }
                        throw EvalMessage(text: "cannot assign to get-only property '\(name)'")
                    }
                    try interpreter.assignComputed(
                        computed,
                        selfValue: .instance(instance),
                        name: name,
                        value: value)
                    return
                }
                if instance.symbol.superclassName != nil,
                   interpreter.interpretedSuperclass(of: instance.symbol) == nil {
                    // Inherited HOST-superclass properties (NSPanel.title):
                    // writes create the box, later reads see the value.
                    instance.properties[name] = Box(stored(value))
                    return
                }
                throw EvalMessage(text: "'\(instance.symbol.name)' has no property '\(name)'")
            case .instanceValueProperty(let base, _, let name):
                let current = try base.read(interpreter).copiedForValueSemantics()
                guard case .instance(let instance) = current, !instance.symbol.isClass else {
                    throw EvalMessage(text: "value-property receiver is not a struct")
                }
                if copyingInput {
                    try LValue.instanceProperty(instance, name).write(value, interpreter)
                } else if resolvingAnnotation {
                    try LValue.instanceProperty(instance, name).writeOwned(value, interpreter)
                } else {
                    try LValue.instanceProperty(instance, name)
                        .writeCanonicalOwned(value, interpreter)
                }
                if resolvingAnnotation {
                    try base.writeOwned(.instance(instance), interpreter)
                } else {
                    try base.writeCanonicalOwned(.instance(instance), interpreter)
                }
            case .hostProperty(let any, let name):
                if let stub = any as? BindingStub, name == "wrappedValue" {
                    // Extension methods on Binding write through the box —
                    // onChange fires the set-closure of computed bindings.
                    stub.box.value = stored(value)
                    return
                }
                // A typed descriptor or explicit compatibility setter makes
                // this a known writable host member, even when the enclosing
                // object is otherwise inert (for example an off-platform SDK
                // value). Only unknown writes fall through to absorption.
                if try interpreter.writeHostMember(name, on: any, to: value) {
                    return
                }
                if any is InertCallable || any is ImplicitMemberCall
                    || any is ChainedImplicitCall {
                    return
                }
                throw EvalMessage(text: "cannot assign to '\(name)' on \(type(of: any))")
            case .element(let base, let index):
                // Read-modify-write through the base lvalue, so element writes
                // propagate box/publisher notifications all the way up.
                guard var array = try base.read(interpreter).arrayValue, array.indices.contains(index) else {
                    throw EvalMessage(text: "array index \(index) out of range")
                }
                let resolved = try base.annotatedElementType().map {
                    try interpreter.resolveAnnotated(value, typeName: $0)
                } ?? value
                array[index] = stored(resolved)
                try base.writeCanonicalOwned(.native(array), interpreter)
            case .dictElement(let base, let key, _):
                let current = try base.read(interpreter)
                guard var dict = current.dictValue else {
                    throw EvalMessage(text: "dictionary lvalue contains \(current.stringified), not a dictionary")
                }
                let types = base.annotatedDictionaryTypes()
                let resolvedKey = try types.map {
                    try interpreter.resolveAnnotated(key, typeName: $0.key)
                } ?? key
                let resolvedValue = try types.map {
                    try interpreter.resolveAnnotated(value, typeName: $0.value)
                } ?? value
                let removesEntry: Bool = {
                    if case .nilValue = value { return true }
                    if case .implicitMember(let name) = value, name == "none" {
                        return true
                    }
                    if case .host(let any) = value,
                       let call = any as? ImplicitMemberCall,
                       call.name == "none", call.arguments.isEmpty {
                        return true
                    }
                    return false
                }()
                if removesEntry {
                    try dict.update(
                        stored(resolvedKey), to: .nilValue,
                        by: interpreter.collectionStorageValuesAreEqual)
                } else {
                    try dict.setValue(
                        stored(resolvedKey), to: stored(resolvedValue),
                        by: interpreter.collectionStorageValuesAreEqual)
                }
                try base.writeCanonicalOwned(.native(dict), interpreter)
            case .tupleElement(let base, let index):
                guard var tuple = try base.read(interpreter).tupleValue,
                      tuple.values.indices.contains(index) else {
                    throw EvalMessage(text: "tuple element \(index) out of range")
                }
                tuple.values[index] = stored(value)
                // Re-write the base so state boxes notify.
                if resolvingAnnotation {
                    try base.writeOwned(.native(tuple), interpreter)
                } else {
                    try base.writeCanonicalOwned(.native(tuple), interpreter)
                }
            case .instanceSubscript(let instance, let args):
                try interpreter.callUserSubscriptSetter(on: instance, with: args, newValue: value)
            case .instanceValueSubscript(let base, let args):
                let current = try base.read(interpreter).copiedForValueSemantics()
                guard case .instance(let instance) = current, !instance.symbol.isClass else {
                    throw EvalMessage(text: "value-subscript receiver is not a struct")
                }
                try interpreter.callUserSubscriptSetter(
                    on: instance, with: args, newValue: stored(value))
                if resolvingAnnotation {
                    try base.writeOwned(.instance(instance), interpreter)
                } else {
                    try base.writeCanonicalOwned(.instance(instance), interpreter)
                }
            case .staticProperty(let symbol, let name):
                if let policy = symbol.staticStoragePolicies[name],
                   policy.referenceOwnership != .strong {
                    let box = symbol.staticReferenceBoxes[name] ?? Box(
                        .none(forTypeAnnotation: policy.typeName ?? ""),
                        declaredTypeName: policy.typeName,
                        referenceOwnership: policy.referenceOwnership)
                    symbol.staticReferenceBoxes[name] = box
                    box.value = stored(value)
                } else {
                    symbol.staticCache[name] = stored(value)
                }
            case .enumStaticProperty(let symbol, let name):
                if let policy = symbol.staticStoragePolicies[name],
                   policy.referenceOwnership != .strong {
                    let box = symbol.staticReferenceBoxes[name] ?? Box(
                        .none(forTypeAnnotation: policy.typeName ?? ""),
                        declaredTypeName: policy.typeName,
                        referenceOwnership: policy.referenceOwnership)
                    symbol.staticReferenceBoxes[name] = box
                    box.value = stored(value)
                } else {
                    symbol.staticCache[name] = stored(value)
                }
            case .dataElement(let base, let index):
                guard case .host(let any) = try base.read(interpreter), var bytes = any as? Data,
                      index >= 0, index < bytes.count, let byte = value.intValue else {
                    throw EvalMessage(text: "Data byte write out of range")
                }
                bytes[bytes.index(bytes.startIndex, offsetBy: index)] = UInt8(truncatingIfNeeded: byte)
                if resolvingAnnotation {
                    try base.writeOwned(.native(bytes), interpreter)
                } else {
                    try base.writeCanonicalOwned(.native(bytes), interpreter)
                }
            case .hostValueMember(let base, let name):
                let baseValue = try base.read(interpreter)
                guard case .host(let any) = baseValue else {
                    throw EvalMessage(text: "cannot assign to '\(name)' on \(baseValue.stringified)")
                }
                var assignedValue = value
                if let property = interpreter.registry?.hostProperty(
                    named: name, on: any) {
                    if let typeName = property.signature.returnType {
                        assignedValue = try interpreter.resolveAnnotated(
                            value, typeName: typeName)
                    }
                    try property.validateWrite(
                        assignedValue, to: .native(any), in: interpreter)
                }
                guard let mutated = try interpreter.registry?.hostMutatedCopy(
                    settingMember: name, on: any, to: assignedValue) else {
                    throw EvalMessage(text: "cannot assign to '\(name)' on \(baseValue.stringified)")
                }
                if resolvingAnnotation {
                    try base.writeOwned(.native(mutated), interpreter)
                } else {
                    try base.writeCanonicalOwned(.native(mutated), interpreter)
                }
            case .nativeWritableStringCollectionView(let base, let name):
                guard let owner = try base.read(interpreter).stringValue,
                      let mutated = try GeneratedCollectionDefaultSurface
                        .replacingNativeWritableStringCollectionView(
                            named: name, in: owner, with: value) else {
                    throw EvalMessage(
                        text: "cannot assign generated String view '\(name)'")
                }
                if resolvingAnnotation {
                    try base.writeOwned(.native(mutated), interpreter)
                } else {
                    try base.writeCanonicalOwned(.native(mutated), interpreter)
                }
            case .forceUnwrapped(let base):
                if !resolvingAnnotation,
                   case .optional(let optional) = try base.read(interpreter) {
                    try base.writeCanonicalOwned(
                        .some(
                            value, wrappedTypeName: optional.wrappedTypeName,
                            isImplicitlyUnwrapped: optional.isImplicitlyUnwrapped),
                        interpreter)
                } else if copyingInput {
                    try base.write(value, interpreter)
                } else {
                    try base.writeOwned(value, interpreter)
                }
            }
        }
    }

    /// Equality THROUGH a user-declared `static func ==` when one applies —
    /// scalars dispatch directly; ARRAYS of such values compare elementwise
    /// through it (`sut == expect` over [Loadable<String>]). nil when no
    /// declared operator is involved; a declared body that trips an
    /// absorbed member falls back to structural (equality never throws).
    /// TYPE-declared operator functions — `static func < (lhs: Self,
    /// rhs: Self)` Comparable conformances and friends. Swift derives
    /// <=/>/>= from a declared `<`. nil when neither operand's type
    /// declares the operator.
    func declaredOperatorValue(
        _ op: String,
        _ lhs: RuntimeValue,
        _ rhs: RuntimeValue,
        lhsDeclaredTypeName: String? = nil,
        rhsDeclaredTypeName: String? = nil
    ) throws -> RuntimeValue? {
        func operatorHome(_ value: RuntimeValue) -> (StructSymbol?, EnumSymbol?) {
            if case .instance(let instance) = value { return (instance.symbol, nil) }
            if case .enumCase(let caseValue) = value { return (nil, caseValue.symbol) }
            return (nil, nil)
        }
        func declared(_ name: String) -> (FunctionDeclSyntax, RuntimeValue)? {
            for operand in [lhs, rhs] {
                let (structSym, enumSym) = operatorHome(operand)
                if let method = structSym?.staticMethods[name]?.first {
                    return (method, .type(structSym!))
                }
                if let method = enumSym?.staticMethods[name]?.first {
                    return (method, .enumType(enumSym!))
                }
            }
            for declaredTypeName in [
                lhsDeclaredTypeName, rhsDeclaredTypeName,
            ] {
                guard let nominal = RuntimeDeclaredType.nominalTypeName(
                    declaredTypeName),
                      let symbol = hostExtensionSymbols[nominal],
                      let overloads = symbol.staticMethods[name] else {
                    continue
                }
                let operandTypes = [
                    lhsDeclaredTypeName, rhsDeclaredTypeName,
                ]
                let method = overloads.first(where: { declaration in
                    let parameters = functionMetadata(
                        for: declaration).parameters
                    guard parameters.count == operandTypes.count else {
                        return false
                    }
                    return zip(parameters, operandTypes).allSatisfy {
                        parameter, operandType in
                        guard let parameterType = parameter.typeName,
                              let operandType else {
                            return false
                        }
                        return HostSignature.equivalentTypeName(
                            parameterType, operandType)
                    }
                }) ?? overloads.first
                guard let method else { continue }
                return (method, .type(symbol))
            }
            return nil
        }
        func runOperator(_ method: FunctionDeclSyntax, _ selfValue: RuntimeValue,
                         _ a: RuntimeValue, _ b: RuntimeValue) throws -> RuntimeValue {
            guard let body = functionMetadata(for: method).body else {
                throw RuntimeError(message: "operator '\(op)' has no body")
            }
            let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(selfValue))
            return try callWithArguments(closure, args: CallArguments(arguments: [
                .init(label: nil, value: a), .init(label: nil, value: b),
            ]), node: nil)
        }
        if ["<", "<=", ">", ">="].contains(op) {
            if let (method, home) = declared(op) {
                return try runOperator(method, home, lhs, rhs)
            }
            if let (less, home) = declared("<") {
                switch op {
                case ">": return try runOperator(less, home, rhs, lhs)
                case "<=":
                    let greater = try runOperator(less, home, rhs, lhs)
                    return .native(!(greater.boolValue ?? false))
                default: // ">="
                    let lesser = try runOperator(less, home, lhs, rhs)
                    return .native(!(lesser.boolValue ?? false))
                }
            }
            return nil
        }
        if let (method, home) = declared(op) {
            return try runOperator(method, home, lhs, rhs)
        }
        return nil
    }

    /// Binary evaluation with full operator semantics for GATEWAYS
    /// (XCTAssert comparisons): declared `==`/`<` and derived forms win
    /// over structural/builtin comparison, exactly like infix expressions.
    public func evaluateBinary(
        _ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue
    ) throws -> RuntimeValue {
        if op == "==" || op == "!=",
           let viaDeclared = try equalsViaDeclaredOperator(lhs, rhs, node: nil) {
            return .bool(op == "==" ? viaDeclared : !viaDeclared)
        }
        do {
            return try Builtins.binary(op, lhs, rhs)
        } catch let builtinError as RuntimeError where !builtinError.fatal {
            if let viaDeclared = try declaredOperatorValue(op, lhs, rhs) { return viaDeclared }
            throw builtinError
        } catch let message as EvalMessage {
            if let viaDeclared = try declaredOperatorValue(op, lhs, rhs) { return viaDeclared }
            throw message
        }
    }

    func equalsViaDeclaredOperator(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue, node: Syntax?
    ) throws -> Bool? {
        // A PAYLOAD-carrying marker beside an enum case resolves against
        // that case's symbol first (`values == [.isLoading(last: nil,
        // cancelBag: .test)]` — the literal rides annotation-less), so the
        // declared `==` compares two real cases.
        var lhs = lhs, rhs = rhs
        func looksLikeMarker(_ value: RuntimeValue) -> Bool {
            if case .implicitMember = value { return true }
            if case .host(let any) = value, any is ImplicitMemberCall { return true }
            return false
        }
        if case .enumCase(let l) = lhs, looksLikeMarker(rhs) {
            rhs = try resolveAnnotated(rhs, typeName: l.symbol.name)
        } else if case .enumCase(let r) = rhs, looksLikeMarker(lhs) {
            lhs = try resolveAnnotated(lhs, typeName: r.symbol.name)
        }
        if let declared = declaredEqualsOperator(lhs) ?? declaredEqualsOperator(rhs) {
            do {
                let result = try callWithArguments(
                    declared,
                    args: CallArguments(arguments: [
                        .init(label: nil, value: lhs), .init(label: nil, value: rhs),
                    ]),
                    node: node)
                if let b = result.boolValue { return b }
            } catch let opError as RuntimeError where !opError.fatal {
                // damus's Route == compares hashValues of absorbed members.
            }
            return nil
        }
        if let synthesized = try memberwiseStructEquality(lhs, rhs, node: node) {
            return synthesized
        }
        if let l = lhs.arrayValue, let r = rhs.arrayValue,
           let sample = l.first ?? r.first,
           declaredEqualsOperator(sample) != nil || isSynthesizableStruct(sample) {
            guard l.count == r.count else { return false }
            for (a, b) in zip(l, r) {
                let pair = try equalsViaDeclaredOperator(a, b, node: node)
                    ?? ((try? Builtins.areEqual(a, b)) ?? false)
                if !pair {
                    if Interpreter.traceStateCells {
                        FileHandle.standardError.write(Data("   ≠ \(a.stringified.prefix(90)) VS \(b.stringified.prefix(90))\n".utf8))
                    }
                    return false
                }
            }
            return true
        }
        if let l = lhs.setValue, let r = rhs.setValue {
            guard l.elements.count == r.elements.count else { return false }
            for element in l.elements {
                var matched = false
                for candidate in r.elements {
                    let pair = try equalsViaDeclaredOperator(
                        element, candidate, node: node)
                        ?? ((try? Builtins.areEqual(element, candidate)) ?? false)
                    if pair {
                        matched = true
                        break
                    }
                }
                if !matched { return false }
            }
            return true
        }
        if let l = lhs.dictValue, let r = rhs.dictValue {
            guard l.count == r.count else { return false }
            for (key, value) in zip(l.keys, l.values) {
                guard let other = try r.value(
                    forKey: key, by: collectionStorageValuesAreEqual)
                else { return false }
                let pair = try equalsViaDeclaredOperator(
                    value, other, node: node)
                    ?? ((try? Builtins.areEqual(value, other)) ?? false)
                if !pair { return false }
            }
            return true
        }
        return nil
    }

    /// Equality used by native collection storage. Unlike the low-level
    /// builtin fallback, this includes declared and synthesized equality for
    /// source values, as required by Set elements and Dictionary keys.
    public func collectionStorageValuesAreEqual(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue
    ) throws -> Bool {
        try equalsViaDeclaredOperator(lhs, rhs, node: nil)
            ?? Builtins.areEqual(lhs, rhs)
    }

    func makeRuntimeSet(
        _ elements: [RuntimeValue], elementTypeName explicitType: String? = nil
    ) throws -> RuntimeSetValue {
        let observedTypes = Set(elements.map(hostTypeName))
        let elementType = explicitType
            ?? (observedTypes.count == 1 ? observedTypes.first : nil)
        return try RuntimeSetValue.deduplicating(
            elements, elementTypeName: elementType,
            by: collectionStorageValuesAreEqual)
    }

    private func isSynthesizableStruct(_ value: RuntimeValue) -> Bool {
        if case .instance(let instance) = value { return !instance.symbol.isClass }
        return false
    }

    /// Member-wise equality for struct instances — the interpreter's stand-in
    /// for Equatable synthesis. Classes keep identity semantics (native
    /// classes never get a synthesized `==`); each member comparison recurses
    /// through declared operators first, exactly like the compiled witness.
    private func memberwiseStructEquality(
        _ lhs: RuntimeValue, _ rhs: RuntimeValue, node: Syntax?
    ) throws -> Bool? {
        guard case .instance(let l) = lhs, case .instance(let r) = rhs,
              !l.symbol.isClass, !r.symbol.isClass else { return nil }
        if l === r { return true }
        guard l.symbol === r.symbol || l.symbol.name == r.symbol.name else { return false }
        let pair = Interpreter.InstanceEqualityPair(
            lhs: ObjectIdentifier(l), rhs: ObjectIdentifier(r))
        guard !activeEqualityPairs.contains(pair) else { return true }
        activeEqualityPairs.insert(pair)
        defer { activeEqualityPairs.remove(pair) }
        let keys = Set(l.properties.keys).union(r.properties.keys)
        for key in keys {
            guard let leftBox = l.properties[key], let rightBox = r.properties[key] else {
                return false
            }
            let same = try equalsViaDeclaredOperator(leftBox.value, rightBox.value, node: node)
                ?? ((try? Builtins.areEqual(leftBox.value, rightBox.value)) ?? false)
            if !same { return false }
        }
        return true
    }

    /// The `static func ==` a value's own type (or its extensions)
    /// declares, as a callable — nil when the type doesn't customize
    /// equality or the declaration is already running (its body's inner
    /// `==` on payloads must fall through to structural equality).
    private func declaredEqualsOperator(_ value: RuntimeValue) -> ClosureValue? {
        let overloads: [FunctionDeclSyntax]?
        let selfValue: RuntimeValue
        let typeName: String
        switch value {
        case .enumCase(let caseValue):
            overloads = caseValue.symbol.staticMethods["=="]
            selfValue = .enumType(caseValue.symbol)
            typeName = caseValue.symbol.name
        case .instance(let instance):
            overloads = instance.symbol.staticMethods["=="]
            selfValue = .type(instance.symbol)
            typeName = instance.symbol.name
        default:
            return nil
        }
        if let method = overloads?.first(where: { !activeFunctionBodies.contains($0.id) }),
           let body = functionMetadata(for: method).body {
            return makeFunctionClosure(method, body: body, captured: selfEnvironment(selfValue))
        }
        // Pre-protocol style: a TOP-LEVEL `func == (lhs: AppState, rhs:
        // AppState) -> Bool` satisfies Equatable too — match by the first
        // parameter's type name (last dotted component, extension-tolerant).
        let wanted = typeName.split(separator: ".").last.map(String.init) ?? typeName
        for decl in globalFunctionOverloads["=="] ?? [] where !activeFunctionBodies.contains(decl.id) {
            let metadata = functionMetadata(for: decl)
            guard let body = metadata.body,
                  let paramType = metadata.parameters.first?.typeName else {
                continue
            }
            let head = paramType.split(separator: ".").last.map(String.init) ?? paramType
            if head == wanted {
                return makeFunctionClosure(decl, body: body, captured: globals)
            }
        }
        return nil
    }

    /// A `.host(ImplicitMemberCall)` beside a NUMERIC/date peer resolves
    /// against the peer's family ("Int"/"Double") so factory statics
    /// (`.random(in:using:)`) execute in operand position. Anything the
    /// factories can't claim returns unchanged (absorb doctrine intact).
    func adoptNumericFactoryMarker(_ value: RuntimeValue, peer: RuntimeValue) throws -> RuntimeValue {
        // ONLY the numeric factory statics — `.init(width:)`-style markers
        // keep their arithmetic-and-rewrap doctrine.
        guard case .host(let any) = value, let call = any as? ImplicitMemberCall,
              call.name == "random" else { return value }
        let familyName: String?
        if peer.intValue != nil {
            familyName = "Int"
        } else if peer.doubleValue != nil {
            familyName = "Double"
        } else if case .host(let peerAny) = peer, peerAny is Date {
            familyName = "Double" // Date ± TimeInterval
        } else {
            familyName = nil
        }
        guard let familyName else { return value }
        // Program shadows win FAMILY-WIDE: native resolves the marker in
        // the expression's contextual type, and mixed Int-literal
        // arithmetic promotes toward Double — so a program extension
        // declaring the factory (the harness determinism shim) claims
        // `-60 * .random(in:)` even though the literal peer reads as Int.
        var resolutionFamily = familyName
        if familyName == "Int",
           hostExtensionSymbols["Int"]?.staticMethods[call.name] == nil,
           hostExtensionSymbols["Double"]?.staticMethods[call.name] != nil {
            resolutionFamily = "Double"
        }
        let resolved = try resolveAnnotated(value, typeName: resolutionFamily)
        if case .host(let stillAny) = resolved, stillAny is ImplicitMemberCall { return value }
        return resolved
    }

    private func dictionaryDefault(
        in call: SubscriptCallExprSyntax, environment: Environment,
        access: LValueAccess
    ) throws -> DictionaryDefault? {
        guard let expression = call.arguments.first(where: {
            $0.label?.text == "default"
        })?.expression else {
            return nil
        }
        switch access {
        case .readModify:
            return .deferred(expression, environment)
        case .writeOnly:
            // Dictionary's setter evaluates its @autoclosure even though the
            // assigned value replaces the element. Preserve that observable
            // side effect; read-modify-write keeps it lazy until a miss.
            return .resolved(try evaluate(expression, in: environment))
        }
    }

    func resolveLValue(
        _ expr: ExprSyntax, in env: Environment,
        access: LValueAccess = .readModify
    ) throws -> LValue {
        // `_ = sideEffect()` — a discard sink.
        if expr.is(DiscardAssignmentExprSyntax.self) {
            return .box(Box(.void))
        }
        // A mutating call reached through optional chaining gets here only
        // after call dispatch has proved the optional contains a payload.
        // Reuse the optional-preserving read/modify/write edge so the changed
        // payload is stored back as some instead of flattening its owner.
        if let chaining = expr.as(OptionalChainingExprSyntax.self) {
            return .forceUnwrapped(try resolveLValue(
                chaining.expression, in: env, access: access))
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if Interpreter.traceStateCells, name == "statusesState" {
                var selfDesc = "none"
                if case .instance(let i)? = env.lookup("self") { selfDesc = i.symbol.name }
                Swift.print("   ⌥ lvalue statusesState envBox=\(env.box(for: name) != nil) self=\(selfDesc)")
            }
            // Real Swift scoping, write side: locals first, implicit-self
            // members second, globals LAST — a property named like a global
            // builtin (`log`, `min`) must not write into the builtin's box.
            if let box = env.box(for: name, before: globals) { return .box(box) }
            if case .instance(let instance)? = env.lookup("self") {
                let canonical = instance.symbol.canonicalPropertyName(name)
                if instance.box(for: canonical) != nil || instance.symbol.computedProperties[canonical] != nil {
                    return .instanceProperty(instance, canonical)
                }
                if instance.symbol.superclassName != nil,
                   interpretedSuperclass(of: instance.symbol) == nil {
                    // Inherited host-superclass property (`title = …` in an
                    // NSPanel subclass) — the write absorbs into a box.
                    return .instanceProperty(instance, canonical)
                }
            }
            // Bare sibling statics inside static methods:
            // `static func show() { shared = … }`.
            if case .type(let symbol)? = env.lookup("self"),
               symbol.staticProperties[name] != nil
                || symbol.staticUninitialized.contains(name)
                || symbol.staticCache[name] != nil {
                return .staticProperty(symbol, name)
            }
            // Bare static COMPUTED setters under a type self
            // (`firstRunDate = Date()` inside a property-initializer
            // closure, the setter living in a private extension).
            if case .type(let symbol)? = env.lookup("self"),
               let computed = symbol.staticComputedProperties[name] {
                if let failure = computed.unsupportedCoroutineModifyError {
                    throw failure
                }
                if let setter = computed.setter {
                    let box = Box(.void)
                    box.onChange = { [weak self] in
                        guard let self else { return }
                        let setterEnv = self.selfEnvironment(.type(symbol))
                        setterEnv.define(setter.parameterName, box.value)
                        _ = try? self.executeBlock(setter.body, in: setterEnv)
                    }
                    return .box(box)
                }
            }
            // Enum namespaces hold mutable statics too (`storage.append(…)`
            // inside a static setter): writes land in the static cache.
            if case .enumType(let symbol)? = env.lookup("self"),
               symbol.staticProperties[name] != nil
                || symbol.staticUninitialized.contains(name)
                || symbol.staticCache[name] != nil {
                return .enumStaticProperty(symbol, name)
            }
            if case .enumType(let symbol)? = env.lookup("self"),
               let computed = symbol.staticComputedProperties[name],
               let failure = computed.unsupportedCoroutineModifyError {
                throw failure
            }
            // Host-typed implicit self (extension-of-host-type bodies):
            // `wrappedValue = …` inside `extension Binding { func load }`
            // writes through the binding's box. Restricted to the binding's
            // OWN properties — other bare names must still reach globals
            // (an absorbing host self would swallow them).
            if case .host(let any)? = env.lookup("self"), any is BindingStub,
               name == "wrappedValue" || name == "projectedValue" {
                return .hostProperty(any, name)
            }
            // No local or member claimed the name — top-level globals last.
            if let box = globals.box(for: name) { return .box(box) }
            throw error(ref, "cannot assign to '\(name)'")
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            // `ChatClient.shared = …` — static stored properties, including
            // host-type extension statics. Locals shadow type names.
            if let baseRef = base.as(DeclReferenceExprSyntax.self),
               env.box(for: baseRef.baseName.text, before: globals) == nil {
                let typeName = baseRef.baseName.text
                let memberName = member.declName.baseName.text
                // `Self.useServer = …` inside a static body: Self IS the
                // enclosing type.
                var typeValue = globals.lookup(typeName)
                if typeName == "Self", let selfValue = env.lookup("self") {
                    typeValue = selfValue
                    // Instance contexts: Self IS the instance's type.
                    if case .instance(let instance) = selfValue {
                        typeValue = .type(instance.symbol)
                    } else if case .enumCase(let caseValue) = selfValue {
                        typeValue = .enumType(caseValue.symbol)
                    }
                }
                var staticSymbol: StructSymbol?
                if case .type(let symbol)? = typeValue {
                    staticSymbol = symbol
                } else if let hostSymbol = hostExtensionSymbols[typeName] {
                    staticSymbol = hostSymbol
                }
                if let symbol = staticSymbol,
                   symbol.staticProperties[memberName] != nil
                    || symbol.staticUninitialized.contains(memberName)
                    || symbol.staticCache[memberName] != nil {
                    return .staticProperty(symbol, memberName)
                }
                if case .enumType(let symbol)? = typeValue,
                   symbol.staticProperties[memberName] != nil
                    || symbol.staticUninitialized.contains(memberName)
                    || symbol.staticCache[memberName] != nil {
                    return .enumStaticProperty(symbol, memberName)
                }
                // Static COMPUTED setters (`static var useServer { get set }`
                // assigned via Self./TypeName.): a Box whose onChange runs
                // the setter — the computed-binding precedent.
                var setterRun: ((RuntimeValue) -> Void)?
                if let symbol = staticSymbol,
                   let computed = symbol.staticComputedProperties[memberName] {
                    if let failure = computed.unsupportedCoroutineModifyError {
                        throw failure
                    }
                    if let setter = computed.setter {
                        setterRun = { [weak self] value in
                            guard let self else { return }
                            let env = self.selfEnvironment(.type(symbol))
                            env.define(setter.parameterName, value)
                            _ = try? self.executeBlock(setter.body, in: env)
                        }
                    }
                } else if case .enumType(let symbol)? = typeValue,
                          let computed = symbol.staticComputedProperties[memberName] {
                    if let failure = computed.unsupportedCoroutineModifyError {
                        throw failure
                    }
                    if let setter = computed.setter {
                        setterRun = { [weak self] value in
                            guard let self else { return }
                            let env = self.selfEnvironment(.enumType(symbol))
                            env.define(setter.parameterName, value)
                            _ = try? self.executeBlock(setter.body, in: env)
                        }
                    }
                }
                if let setterRun {
                    let box = Box(.void)
                    box.onChange = { setterRun(box.value) }
                    return .box(box)
                }
            }
            let evaluatedBaseValue = try evaluate(base, in: env)
            var baseValue = evaluatedBaseValue
            var optionalPayloadOwner: LValue?
            if case .optional(let optional) = evaluatedBaseValue,
               optional.isImplicitlyUnwrapped || containsOptionalChaining(base) {
                guard let wrapped = optional.wrapped else {
                    // Assignment through a nil optional chain is a no-op.
                    // An unavailable IUO in whole-project artifact mode uses
                    // the same absorbing write boundary.
                    if containsOptionalChaining(base) || assumesCompiledImports {
                        return .hostProperty(
                            ImplicitMemberCall(
                                name: "nil", arguments: CallArguments()),
                            member.declName.baseName.text)
                    }
                    throw error(
                        member,
                        "unexpectedly found nil while implicitly unwrapping")
                }
                baseValue = wrapped
                let storageExpression = base.as(OptionalChainingExprSyntax.self)?
                    .expression ?? base
                if let storage = try? resolveLValue(storageExpression, in: env) {
                    optionalPayloadOwner = .forceUnwrapped(storage)
                }
            }
            if case .instance(let instance) = baseValue {
                let name = instance.symbol.canonicalPropertyName(member.declName.baseName.text)
                let owner = optionalPayloadOwner ?? (try? resolveLValue(base, in: env))
                if !instance.symbol.isClass, let owner {
                    return .instanceValueProperty(owner, instance.symbol, name)
                }
                return .instanceProperty(instance, name)
            }
            if let tuple = baseValue.tupleValue {
                let memberName = member.declName.baseName.text
                let index = Int(memberName) ?? tuple.labels.firstIndex(of: memberName) ?? -1
                let owner = optionalPayloadOwner ?? (try? resolveLValue(base, in: env))
                if tuple.values.indices.contains(index), let owner {
                    return .tupleElement(owner, index)
                }
            }
            let memberName = member.declName.baseName.text
            if baseValue.stringValue != nil,
               GeneratedCollectionDefaultSurface
                .isNativeWritableStringCollectionView(named: memberName),
               let owner = optionalPayloadOwner
                ?? (try? resolveLValue(base, in: env)) {
                return .nativeWritableStringCollectionView(owner, memberName)
            }
            if case .host(let any) = baseValue {
                // `binding.wrappedValue = …` writes straight through the box.
                if let stub = any as? BindingStub, member.declName.baseName.text == "wrappedValue" {
                    return .box(stub.box)
                }
                if hasRuntimeAsyncStreamMember(memberName, on: any) {
                    return .hostProperty(any, memberName)
                }
                if registry != nil {
                    // VALUE types (CGSize/CGPoint/CGRect…) write through a
                    // mutated copy so the base re-writes and notifies. Only
                    // structs with a readable same-named member route here;
                    // class-backed boxes keep hostProperty reference writes.
                    if !(type(of: any) is AnyClass),
                       hasHostMember(memberName, on: any),
                       let owner = optionalPayloadOwner
                        ?? (try? resolveLValue(base, in: env)) {
                        return .hostValueMember(owner, memberName)
                    }
                    // Host objects with settable members (formatter.dateFormat = …).
                    return .hostProperty(any, memberName)
                }
            }
            if case .implicitMember(let markerName) = baseValue {
                // Config writes on unresolved host statics are accepted and
                // ignored (the marker-write doctrine).
                return .hostProperty(
                    ImplicitMemberCall(name: markerName, arguments: CallArguments()),
                    member.declName.baseName.text)
            }
            if case .hostFunction(let fn) = baseValue {
                // `LaunchAtLogin.isEnabled = …` — external-package statics
                // resolve to constructor functions; writes are accepted.
                return .hostProperty(
                    ImplicitMemberCall(name: fn.name, arguments: CallArguments()),
                    member.declName.baseName.text)
            }
            if assumesCompiledImports, baseValue.isNil || {
                if case .void = baseValue { return true } else { return false }
            }() {
                // A nil/void base from absorbed chains (`sequencer.tracks[1]`
                // on a fresh store; a DI property nothing injected): the
                // write is accepted and ignored, the marker-write doctrine.
                return .hostProperty(
                    ImplicitMemberCall(name: "nil", arguments: CallArguments()),
                    member.declName.baseName.text)
            }
            throw error(member, "cannot assign to a member of \(baseValue.stringified)")
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            guard let indexExpr = subscriptCall.arguments.first?.expression else {
                throw error(subscriptCall, "missing subscript index")
            }
            let baseValue = try? evaluateContextualReceiver(
                subscriptCall.calledExpression, in: env)
            if case .instance(let instance)? = baseValue, !instance.symbol.subscripts.isEmpty {
                let indexArgs = CallArguments(arguments: try subscriptCall.arguments.map {
                    .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
                })
                if !instance.symbol.isClass,
                   let owner = try? resolveLValue(subscriptCall.calledExpression, in: env) {
                    return .instanceValueSubscript(owner, indexArgs)
                }
                return .instanceSubscript(instance, indexArgs)
            }
            if baseValue?.dictValue != nil {
                let fallback = try dictionaryDefault(
                    in: subscriptCall, environment: env, access: access)
                let base = try resolveLValue(subscriptCall.calledExpression, in: env)
                return .dictElement(base, try evaluate(indexExpr, in: env), fallback: fallback)
            }
            // `element[keyPath: kp] = value` — keypath writes walk to the
            // last component's owner and assign the property.
            if subscriptCall.arguments.first?.label?.text == "keyPath" {
                let keyValue = try evaluate(indexExpr, in: env)
                if case .host(let any) = keyValue, let stub = any as? KeyPathStub,
                   let last = stub.components.last, last != "self" {
                    var owner = try evaluate(subscriptCall.calledExpression, in: env)
                    for component in stub.components.dropLast() where component != "self" {
                        owner = try accessMember(component, on: owner, node: subscriptCall, env: env)
                    }
                    if case .instance(let instance) = owner {
                        return .instanceProperty(instance, instance.symbol.canonicalPropertyName(last))
                    }
                }
                throw error(subscriptCall, "unsupported keyPath assignment target")
            }
            // Store WRITES remember (`Defaults[.previewWidth] = w`): the
            // key bag's declared default updates, so later reads round-trip
            // within the run — fresh-store bag semantics.
            if let keyBag = try storeKeyBag(base: baseValue, indexExpr: indexExpr, in: env) {
                let seed = registry?.hostMember("default", on: keyBag) ?? .void
                let box = Box(seed)
                box.onChange = { [weak self] in
                    _ = self?.registry?.hostSetMember("default", on: keyBag, to: box.value)
                }
                return .box(box)
            }
            // USER-DECLARED subscript setters (`appState[\\.route] = x` on
            // clean-architecture's Store): seed from the getter, write
            // through the setter — declared semantics beat element writes.
            if let owningBase = baseValue,
               let (symbol, selfValue) = userSubscriptOwner(for: owningBase),
               symbol.subscripts.contains(where: { $0.setter != nil }) {
                let indexArgs = CallArguments(arguments: try subscriptCall.arguments.map {
                    .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
                })
                let seed = (try? runUserSubscriptGetter(symbol, selfValue: selfValue, args: indexArgs)) ?? .void
                let box = Box(seed)
                box.onChange = { [weak self] in
                    guard let self else { return }
                    try? self.runUserSubscriptSetter(
                        symbol, selfValue: selfValue, args: indexArgs, newValue: box.value)
                }
                return .box(box)
            }
            let base = try resolveLValue(subscriptCall.calledExpression, in: env)
            let indexValue = try evaluate(indexExpr, in: env)
            guard let index = indexValue.intValue else {
                // KEYED assignment onto a DEFERRED store (`var routers:
                // [Tab: Router]` initialized in an init our synthesis
                // skipped): the dictionary auto-vivifies.
                let current = try base.read(self)
                let isVoid: Bool = { if case .void = current { return true } else { return false } }()
                let isMarker: Bool = {
                    if let payload = current.hostPayload {
                        return payload is InertCallable || payload is ChainedImplicitCall
                            || payload is ImplicitMemberCall
                    }
                    if case .implicitMember = current { return true }
                    if case .hostFunction = current { return true }
                    return false
                }()
                let fallback = try dictionaryDefault(
                    in: subscriptCall, environment: env, access: access)
                if current.isNil || isVoid || isMarker {
                    let dict = DictValue()
                    try base.write(.native(dict), self)
                    return .dictElement(base, indexValue, fallback: fallback)
                }
                if current.dictValue != nil {
                    return .dictElement(base, indexValue, fallback: fallback)
                }
                throw error(subscriptCall, "subscript assignment requires an Int index")
            }
            if case .host(let any)? = baseValue, any is Data {
                return .dataElement(base, index) // byte write-through
            }
            return .element(base, index)
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return try resolveLValue(only.expression, in: env, access: access)
        }
        // `components.hour! += 1` — optionals ARE the value, so the
        // force-unwrap lvalue writes through the wrapped path.
        if let force = expr.as(ForceUnwrapExprSyntax.self) {
            return .forceUnwrapped(
                try resolveLValue(force.expression, in: env))
        }
        throw error(expr, "expression is not assignable")
    }
}
