import Foundation
import SwiftSyntax

extension Interpreter {
    // MARK: - Literals & helpers

    func integerValue(of lit: IntegerLiteralExprSyntax) throws -> Int {
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
                    let value = try evaluate(labeled.expression, in: env)
                    // Unknowables read "" in string interpolation — the
                    // fresh-string doctrine; internal marker dumps must
                    // never reach rendered Text.
                    if case .host(let any) = value,
                       any is InertCallable || any is ChainedImplicitCall
                        || any is ImplicitMemberCall {
                        continue
                    }
                    if case .implicitMember = value { continue }
                    if case .hostFunction = value { continue }
                    out += value.stringified
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

    /// Library key-value stores with DECLARED key defaults (sindresorhus/
    /// Defaults): `Store[.key]` resolves `Store.Keys.key`'s bag, whose
    /// `default:` argument is the fresh-store value (reads) and updates on
    /// writes.
    func storeKeyBag(base: RuntimeValue?, indexExpr: ExprSyntax, in env: Environment) throws -> Any? {
        guard let base else { return nil }
        guard case .implicitMember = try evaluate(indexExpr, in: env) else { return nil }
        return try storeKeyBag(base: base, index: try evaluate(indexExpr, in: env))
    }

    private func storeKeyBag(base: RuntimeValue, index: RuntimeValue) throws -> Any? {
        let storeTypeName: String? = {
            if case .host(let baseAny) = base, let marker = baseAny as? HostTypeMarker {
                return marker.name
            }
            if case .hostFunction(let fn) = base { return fn.name } // ctor catch-all
            if case .enumType(let symbol) = base { return symbol.name } // vendored store
            if case .type(let symbol) = base { return symbol.name }
            return nil
        }()
        guard let storeTypeName,
              case .implicitMember(let keyName) = index,
              let keysSymbol = hostExtensionSymbols["\(storeTypeName).Keys"],
              let keyValue = try staticMember(keyName, of: keysSymbol),
              case .host(let keyAny) = keyValue else { return nil }
        return keyAny
    }

    func evaluateSubscript(_ call: SubscriptCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        let base = try evaluate(call.calledExpression, in: env)
        if base.isNil { return .nilValue }
        guard let indexExpr = call.arguments.first?.expression else {
            throw error(call, "missing subscript index")
        }
        let index = try evaluate(indexExpr, in: env)
        // EnvironmentValues getters: `self[Key.self]` reads the key type's
        // static defaultValue (pre-@Entry EnvironmentKey conformances).
        if case .host(let any) = base, any is EnvironmentValuesStub {
            if case .type(let keySymbol) = index {
                return try staticMember("defaultValue", of: keySymbol) ?? .nilValue
            }
            return .nilValue
        }
        if call.arguments.first?.label?.text == "keyPath" {
            // `element[keyPath: kp]` — apply the stub's components.
            if case .host(let any) = index, let stub = any as? KeyPathStub {
                return try applyKeyPath(stub, to: base)
            }
            return .nilValue // unknowable keypath: fresh read
        }
        if let array = base.arrayValue {
            if let i = index.intValue, array.indices.contains(i) {
                return array[i]
            }
            if let range = index.rangeValue {
                let bounds = try integerSlice(range, count: array.count, name: "array", node: call)
                return .native(Array(array[bounds]))
            }
            throw error(call, "array index out of range")
        }
        if let dict = base.dictValue {
            let found = try relocating(call) { try dict.lookup(index) }
            // `sales[key, default: 0]` — missing keys read the default.
            if found.isNil,
               let defaultExpr = call.arguments.first(where: { $0.label?.text == "default" })?.expression {
                return try evaluate(defaultExpr, in: env)
            }
            return found
        }
        if let range = base.rangeValue, let i = index.intValue {
            guard let materialized = range.integerValues() else {
                throw error(call, "only integer ranges can be indexed")
            }
            guard materialized.indices.contains(i) else { throw error(call, "range index out of range") }
            return materialized[i]
        }
        if case .host(let any) = base, let stub = any as? BindingStub, let i = index.intValue {
            // `$items[index]` — a write-through element binding.
            guard let element = stub.elementBinding(at: i) else {
                throw error(call, "binding index out of range")
            }
            return element
        }
        if let (symbol, selfValue) = userSubscriptOwner(for: base) {
            // User subscript getter: `matrix[index]` / `grid[x, y]` — and
            // host-extension subscripts (`appState[\\.permissions.push]`).
            let indexArgs = CallArguments(arguments: try call.arguments.map {
                .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
            })
            return try relocating(call) {
                try runUserSubscriptGetter(symbol, selfValue: selfValue, args: indexArgs)
            }
        }
        if case .host(let stringAny) = base, let string = stringAny as? String {
            // `text[range]` / `text[i]` with String.Index values.
            if let range = index.rangeValue {
                return .native(String(string[try stringSlice(range, in: string, node: call)]))
            }
            if case .host(let indexAny) = index,
               let position = indexAny as? String.Index,
               position >= string.startIndex, position < string.endIndex {
                    return .native(String(string[position]))
            }
        }
        // Library key-value stores with DECLARED defaults (sindresorhus/
        // Defaults: `Defaults[.windowSize]` with `Defaults.Keys.windowSize =
        // Key("…", default: NSSize(…))`): a fresh store answers the key's
        // declared default — the @Default-wrapper doctrine at subscript level.
        if let keyBag = try storeKeyBag(base: base, index: index),
           let declared = registry?.hostMember("default", on: keyBag)
               ?? registry?.hostMember("defaultValue", on: keyBag) {
            return declared
        }
        if case .host(let any) = base,
           case .hostFunction(let subscripting)? = registry?.hostMember("subscript", on: any) {
            // Host subscripts (AttributedString[range] styling proxies).
            let args = CallArguments(arguments: [.init(label: nil, value: index)])
            return try relocating(call) { try subscripting.invoke(args, self) }
        }
        if case .host(let dataAny) = base, let bytes = dataAny as? Data {
            // Byte access and slices (bech32 decoders index raw buffers).
            if let i = index.intValue {
                guard i >= 0, i < bytes.count else {
                    throw error(call, "Data index \(i) out of range")
                }
                return .native(Int(bytes[bytes.index(bytes.startIndex, offsetBy: i)]))
            }
            if let range = index.rangeValue {
                let bounds = try integerSlice(range, count: bytes.count, name: "Data", node: call)
                let start = bytes.index(bytes.startIndex, offsetBy: bounds.lowerBound)
                let end = bytes.index(bytes.startIndex, offsetBy: bounds.upperBound)
                return .native(Data(bytes[start..<end]))
            }
        }
        // A TYPE base that isn't a declared-default store: in compiled
        // mode the subscript is a static-subscript surface the merge can't
        // model (a vendored Defaults shim shadowed by a design-token
        // namespace) — absorbs.
        if assumesCompiledImports {
            if case .enumType = base {
                return .native(ChainedImplicitCall(
                    base: base, member: "subscript",
                    arguments: CallArguments(arguments: [.init(label: nil, value: index)])))
            }
            if case .type = base {
                return .native(ChainedImplicitCall(
                    base: base, member: "subscript",
                    arguments: CallArguments(arguments: [.init(label: nil, value: index)])))
            }
        }
        // Subscripting an unknowable host collection (Bundle.main
        // .infoDictionary?[…]) reads nil — the empty fresh store; the
        // caller's ?? fallback applies, as on a device without that key.
        if case .host(let any) = base,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            return .nilValue
        }
        if case .implicitMember = base { return .nilValue }
        if case .hostFunction = base { return .nilValue }
        throw error(call, "subscripting is only supported on arrays and dictionaries, got \(base.stringified)")
    }

    private func integerSlice(
        _ range: RuntimeRangeValue,
        count: Int,
        name: String,
        node: some SyntaxProtocol
    ) throws -> Range<Int> {
        let lower = range.lowerBound?.intValue ?? 0
        var upper = range.upperBound?.intValue ?? count
        if range.includesUpperBound, range.upperBound != nil {
            guard upper < count else { throw error(node, "\(name) slice out of bounds") }
            upper += 1
        }
        guard lower >= 0, upper <= count, lower <= upper else {
            throw error(node, "\(name) slice out of bounds")
        }
        return lower..<upper
    }

    func stringSlice(
        _ range: RuntimeRangeValue,
        in string: String,
        node: some SyntaxProtocol
    ) throws -> Range<String.Index> {
        func index(_ value: RuntimeValue?, fallback: String.Index) throws -> String.Index {
            guard let value else { return fallback }
            if let offset = value.intValue {
                guard offset >= 0, offset <= string.count else {
                    throw error(node, "string slice out of bounds")
                }
                return string.index(string.startIndex, offsetBy: offset)
            }
            if case .host(let any) = value, let index = any as? String.Index {
                return index
            }
            throw error(node, "string slice needs Int or String.Index bounds")
        }

        let lower = try index(range.lowerBound, fallback: string.startIndex)
        var upper = try index(range.upperBound, fallback: string.endIndex)
        if range.includesUpperBound, range.upperBound != nil {
            guard upper < string.endIndex else { throw error(node, "string slice out of bounds") }
            upper = string.index(after: upper)
        }
        guard lower >= string.startIndex, upper <= string.endIndex, lower <= upper else {
            throw error(node, "string slice out of bounds")
        }
        return lower..<upper
    }

    func expectBool(_ value: RuntimeValue, node: some SyntaxProtocol) throws -> Bool {
        guard let b = value.boolValue else {
            // Hosted-object truths (`context.canEvaluatePolicy(…)`,
            // `engine.isRunning`) read their fresh-state value — FALSE for
            // everything except `isEmpty` chains, which read TRUE (the
            // fresh store's collection is empty, agreeing with for-in).
            if let fresh = Builtins.unknowableBool(value) { return fresh }
            // A VOID Bool can't compile natively — an absorbed-environment
            // artifact reading fresh false.
            if case .void = value { return false }
            // Nil from optional chains through stubs reads false too.
            if value.isNil { return false }
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
