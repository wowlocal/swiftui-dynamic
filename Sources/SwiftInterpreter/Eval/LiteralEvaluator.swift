import Foundation
import SwiftSyntax

extension Interpreter {
    // MARK: - Literals & helpers

    private func unsignedIntegerMagnitude(
        of lit: IntegerLiteralExprSyntax
    ) -> UInt64? {
        let text = lit.literal.text.filter { $0 != "_" }
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        if text.hasPrefix("0b") { return UInt64(text.dropFirst(2), radix: 2) }
        if text.hasPrefix("0o") { return UInt64(text.dropFirst(2), radix: 8) }
        return UInt64(text, radix: 10)
    }

    func unsignedIntegerValue(of lit: IntegerLiteralExprSyntax) throws -> UInt64 {
        guard let value = unsignedIntegerMagnitude(of: lit) else {
            throw error(lit, "invalid integer literal")
        }
        return value
    }

    func integerValue(of lit: IntegerLiteralExprSyntax) throws -> Int {
        let magnitude = try unsignedIntegerValue(of: lit)
        guard let value = Int(exactly: magnitude) else {
            throw error(lit, "integer literal does not fit Int")
        }
        return value
    }

    func integerLiteralValue(of lit: IntegerLiteralExprSyntax) throws -> RuntimeValue {
        let magnitude = try unsignedIntegerValue(of: lit)
        if let value = Int(exactly: magnitude) { return .native(value) }
        return .native(magnitude)
    }

    func stringLiteral(
        _ lit: StringLiteralExprSyntax,
        in env: Environment
    ) throws -> RuntimeValue {
        try evaluatedStringLiteral(lit, in: env).value
    }

    /// A string literal evaluated ONCE, reported in both readings it can have.
    ///
    /// `value` is the ordinary `String` (or attachment carrier) every consumer
    /// already receives. `localized` is present only when the literal has an
    /// interpolation whose type carries a format specifier, and is what a host
    /// adapter with a `LocalizedStringKey` parameter reads instead. Evaluating
    /// once and reporting twice is the point: re-evaluating the literal to get
    /// the second reading would run its interpolations' side effects again.
    struct EvaluatedStringLiteral {
        let value: RuntimeValue
        let localized: RuntimeLocalizedStringLiteral?
    }

    func evaluatedStringLiteral(
        _ lit: StringLiteralExprSyntax,
        in env: Environment
    ) throws -> EvaluatedStringLiteral {
        if let simple = lit.representedLiteralValue {
            if let contextual = try contextualStringLiteral(
                simple, environment: env
            ) {
                return .init(value: contextual, localized: nil)
            }
            return .init(value: .native(simple), localized: nil)
        }
        var out = ""
        var segments: [RuntimeInterpolatedString.Segment] = []
        var localizedSegments: [RuntimeLocalizedStringLiteral.Segment] = []
        var hasAttachment = false
        var hasFormatSpecifier = false

        func appendText(_ text: String) {
            out += text
            segments.append(.text(text))
            localizedSegments.append(.text(text))
        }

        func appendInterpolation(_ value: RuntimeValue) {
            if case .host(let any) = value,
               any is RuntimeStringInterpolationAttachment {
                hasAttachment = true
                segments.append(.attachment(value))
                if let text = interpolationText(value) {
                    out += text
                    localizedSegments.append(.text(text))
                }
            } else if let text = interpolationText(value) {
                out += text
                segments.append(.text(text))
                // The SAME value under both readings: verbatim in `out`, and
                // specifier-formatted for a localization key when its type
                // supplies one.
                if let specifier = value.localizedFormatSpecifier {
                    hasFormatSpecifier = true
                    localizedSegments.append(
                        .formatted(value, specifier: specifier))
                } else {
                    localizedSegments.append(.text(text))
                }
            }
        }

        for segment in lit.segments {
            switch segment {
            case .stringSegment(let s):
                appendText(unescape(s.content.text))
            case .expressionSegment(let e):
                // Keep ordinary `\(value)` on the original allocation-free
                // path; labeled interpolation is the uncommon case.
                if e.expressions.count == 1, let only = e.expressions.first,
                   only.label == nil {
                    let value = try evaluate(only.expression, in: env)
                    appendInterpolation(value)
                    continue
                }
                // One expression segment is one appendInterpolation call.
                // Its labeled controls are arguments, not extra output.
                // Evaluate every argument once, left-to-right, before
                // applying the selected interpolation behavior.
                var arguments: [(label: String?, value: RuntimeValue)] = []
                for labeled in e.expressions {
                    arguments.append((
                        labeled.label?.text,
                        try evaluate(labeled.expression, in: env)))
                }
                guard let value = arguments.first?.value else { continue }
                if let specifierArgument = arguments.first(where: {
                    $0.label == "specifier"
                }) {
                    guard let specifier = specifierArgument.value.stringValue else {
                        throw error(e, "string interpolation specifier must be a String")
                    }
                    // `specifier:` interpolation exists ONLY on
                    // LocalizedStringKey, so this segment is always a
                    // localization-key segment; the locale-less rendering
                    // stays in `out` as the plain reading.
                    let text = Self.cFormattedString(specifier, values: [value])
                    out += text
                    segments.append(.text(text))
                    hasFormatSpecifier = true
                    localizedSegments.append(
                        .formatted(value, specifier: specifier))
                    continue
                }
                if let styleArgument = arguments.first(where: {
                    $0.label == "format"
                }) {
                    // `appendInterpolation(_:format:)`, the sibling of
                    // `specifier:` above and equally a localization-key
                    // interpolation, so this segment is always a
                    // localization-key segment. The style is an SDK generic
                    // this layer cannot build, so it rides unresolved to the
                    // host beside the value; the specifier-free reading stays
                    // in `out` as the plain reading.
                    let text = interpolationText(value) ?? ""
                    out += text
                    segments.append(.text(text))
                    hasFormatSpecifier = true
                    // The fallback, for when no host resolves the style, is
                    // the reading this same interpolation would have had with
                    // no `format:` label at all — so an unresolved style
                    // degrades to the localized `874,788` that dropping the
                    // label produces, never to a grouping-free `874788` that
                    // no overload of this interpolation ever yields.
                    let fallback = value.localizedFormatSpecifier.map {
                        Self.cFormattedString(
                            $0, values: [value], locale: .current)
                    } ?? text
                    localizedSegments.append(
                        .styled(
                            value, style: styleArgument.value,
                            verbatim: fallback))
                    continue
                }
                appendInterpolation(value)
            }
        }
        let localized = hasFormatSpecifier
            ? RuntimeLocalizedStringLiteral(
                segments: localizedSegments, plainText: out)
            : nil
        if hasAttachment {
            return .init(
                value: .native(RuntimeInterpolatedString(
                    segments: segments,
                    plainText: out)),
                localized: localized)
        }
        return .init(value: .native(out), localized: localized)
    }

    /// A literal is converted only when its contextual nominal type declares
    /// the standard library protocol requirement. This keeps conversion
    /// driven by source type structure: ordinary String-valued expressions
    /// never acquire an implicit nominal conversion, and no conforming SDK or
    /// application type needs an identity-keyed gateway.
    private func contextualStringLiteral(
        _ value: String, environment: Environment
    ) throws -> RuntimeValue? {
        guard var typeName = expectedAnnotationText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !typeName.isEmpty else {
            return nil
        }
        while let wrapped = RuntimeOptionalValue.wrappedType(in: typeName) {
            typeName = wrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !typeName.contains("<") else { return nil }

        let environmentOwner: AnyObject? = {
            switch environment.lookup("self") {
            case .type(let symbol)?: return symbol
            case .enumType(let symbol)?: return symbol
            default: return nil
            }
        }()
        guard case .type(let symbol)? = lexicallyVisibleType(
            named: typeName,
            from: environmentOwner ?? lexicalOwnerFrames.last
        ), transitiveConformances(of: symbol).contains(where: {
            $0.split(separator: ".").last == "ExpressibleByStringLiteral"
        }) else {
            return nil
        }

        let declaresRequirement = symbol.initializers.contains { initializer in
            let metadata = initializerMetadata(for: initializer)
            return metadata.parameters.count == 1
                && metadata.parameters[0].label == "stringLiteral"
                && metadata.parameters[0].defaultValue == nil
                && !metadata.isAsync
                && !metadata.isThrowing
        }
        guard declaresRequirement else { return nil }
        return try instantiate(
            symbol,
            with: CallArguments(arguments: [
                .init(label: "stringLiteral", value: .native(value)),
            ]))
    }

    private func interpolationText(_ value: RuntimeValue) -> String? {
        // Unknowables read "" in string interpolation — the fresh-string
        // doctrine; internal marker dumps must never reach rendered Text.
        if case .host(let any) = value,
           any is InertCallable || any is ChainedImplicitCall
            || any is ImplicitMemberCall {
            return nil
        }
        if case .implicitMember = value { return nil }
        if case .hostFunction = value { return nil }
        return value.stringified
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

    /// A computed receiver can return an implicit static (`var manager:
    /// Manager { .shared }`). Keep getters lazy in general, but resolve that
    /// marker when an operation needs the receiver's declared semantics.
    func evaluateContextualReceiver(
        _ expression: ExprSyntax, in env: Environment
    ) throws -> RuntimeValue {
        let value: RuntimeValue
        var annotation: TypeSyntax?

        // Evaluate a member base exactly once. Re-evaluating it merely to
        // discover the computed property's annotation would duplicate side
        // effects in expressions such as `makeOwner().manager[token]`.
        if let member = expression.as(MemberAccessExprSyntax.self),
           let ownerExpression = member.base {
            let owner = try evaluate(ownerExpression, in: env)
            value = try accessMember(
                member.declName.baseName.text, on: owner, node: member, env: env)
            switch owner {
            case .instance(let instance):
                annotation = instance.symbol.computedProperties[
                    member.declName.baseName.text]?.typeAnnotation
            case .type(let symbol):
                annotation = symbol.staticComputedProperties[
                    member.declName.baseName.text]?.typeAnnotation
            case .enumType(let symbol):
                annotation = symbol.staticComputedProperties[
                    member.declName.baseName.text]?.typeAnnotation
            default:
                break
            }
        } else {
            value = try evaluate(expression, in: env)
            if let reference = expression.as(DeclReferenceExprSyntax.self) {
                switch env.lookup("self") {
                case .instance(let instance)?:
                    annotation = instance.symbol.computedProperties[
                        reference.baseName.text]?.typeAnnotation
                case .type(let symbol)?:
                    annotation = symbol.staticComputedProperties[
                        reference.baseName.text]?.typeAnnotation
                case .enumType(let symbol)?:
                    annotation = symbol.staticComputedProperties[
                        reference.baseName.text]?.typeAnnotation
                default:
                    break
                }
            }
        }

        let unresolved: Bool = {
            if case .implicitMember = value { return true }
            if case .host(let any) = value {
                return any is ImplicitMemberCall || any is ChainedImplicitCall
            }
            return false
        }()
        guard unresolved else { return value }
        guard let annotation else { return value }
        return try resolveAnnotated(value, annotation: annotation)
    }

    func evaluateSubscript(_ call: SubscriptCallExprSyntax, in env: Environment) throws -> RuntimeValue {
        let evaluatedBase = try evaluateContextualReceiver(
            call.calledExpression, in: env)
        let base: RuntimeValue
        let isOptionalChain: Bool
        switch evaluatedBase.optionalState {
        case .some(let wrapped, _):
            base = wrapped
            isOptionalChain = true
        case .none:
            return .none()
        case .notOptional:
            base = evaluatedBase
            isOptionalChain = false
        }
        func chained(_ value: RuntimeValue) -> RuntimeValue {
            isOptionalChain ? value.liftedToOptional() : value
        }
        guard let indexExpr = call.arguments.first?.expression else {
            throw error(call, "missing subscript index")
        }
        let index = try evaluate(indexExpr, in: env)
        // EnvironmentValues getters: `self[Key.self]` reads the key type's
        // static defaultValue (pre-@Entry EnvironmentKey conformances).
        if case .host(let any) = base, any is EnvironmentValuesStub {
            switch index {
            case .type(let keySymbol):
                return chained(
                    try staticMember("defaultValue", of: keySymbol) ?? .nilValue)
            case .enumType(let keySymbol):
                return chained(
                    try staticMember("defaultValue", of: keySymbol) ?? .nilValue)
            default:
                return .nilValue
            }
        }
        if call.arguments.first?.label?.text == "keyPath" {
            // `element[keyPath: kp]` — apply the stub's components.
            if case .host(let any) = index, let stub = any as? KeyPathStub {
                return chained(try applyKeyPath(stub, to: base))
            }
            return .nilValue // unknowable keypath: fresh read
        }
        // Indexed carriers retain element type and can read without
        // materializing their full collection view. Range subscripts still
        // fall through to the ordinary collection path below.
        if let position = index.intValue,
           case .host(let payload) = base,
           let readable = payload as? any RuntimeIntegerSubscriptReadable {
            return chained(try relocating(call) {
                try readable.runtimeElement(at: position)
            })
        }
        if let array = base.arrayValue {
            // The receiver's OWN index space: for a slice that is its base's,
            // so an absolute index reads the element it names in the base and
            // a sub-slice composes instead of re-basing a second time.
            let source = base.arraySliceValue ?? array[...]
            if let i = index.intValue, source.indices.contains(i) {
                return chained(source[i])
            }
            if let range = index.rangeValue {
                // Bounds are ABSOLUTE indices in the receiver's own space, not
                // offsets from the slice's start: `b[2...][4...]` begins at 4,
                // not at 6. An omitted bound is the receiver's own start/end,
                // so a whole array (start 0) resolves exactly as before.
                //
                // The RESULT keeps that space. `Array(...)` here would re-base
                // it to zero and break every reader that walks a buffer by
                // slicing what is left — SwiftSoup's
                // `CharacterReader.nextIndexOf` does exactly that
                // (`input[pos...].firstIndex(of:)`, then `pos = targetIx`), so
                // a re-based index sends its cursor backwards and its
                // entity-table loop never terminates.
                let lower = range.lowerBound?.intValue ?? source.startIndex
                var upper = range.upperBound?.intValue ?? source.endIndex
                if range.includesUpperBound, range.upperBound != nil {
                    guard upper < source.endIndex else {
                        throw error(call, "array slice out of bounds")
                    }
                    upper += 1
                }
                guard lower >= source.startIndex, upper <= source.endIndex,
                      lower <= upper else {
                    throw error(call, "array slice out of bounds")
                }
                return chained(.native(source[lower..<upper]))
            }
            throw error(call, "array index out of range")
        }
        if let dict = base.dictValue {
            let found = try relocating(call) {
                try dict.value(
                    forKey: index, by: collectionStorageValuesAreEqual)
            }
            // Dictionary's `default:` subscript returns Value, not Value?.
            // Its @autoclosure runs only for a missing key on the read path.
            if let defaultExpr = call.arguments.first(where: {
                $0.label?.text == "default"
            })?.expression {
                if let found { return chained(found) }
                return chained(try evaluate(defaultExpr, in: env))
            }
            return found.map { .some($0) } ?? .none()
        }
        if let range = base.rangeValue, let i = index.intValue {
            guard let materialized = range.integerValues() else {
                throw error(call, "only integer ranges can be indexed")
            }
            guard materialized.indices.contains(i) else { throw error(call, "range index out of range") }
            return chained(materialized[i])
        }
        if case .host(let any) = base, let stub = any as? BindingStub, let i = index.intValue {
            // `$items[index]` — a write-through element binding.
            guard let element = stub.elementBinding(at: i) else {
                throw error(call, "binding index out of range")
            }
            return chained(element)
        }
        if let (symbol, selfValue) = userSubscriptOwner(for: base) {
            // User subscript getter: `matrix[index]` / `grid[x, y]` — and
            // host-extension subscripts (`appState[\\.permissions.push]`).
            var indexArgs = CallArguments(arguments: try call.arguments.map {
                .init(label: $0.label?.text, value: try evaluate($0.expression, in: env))
            })
            if indexArgs.arguments.count == 1,
               matchingUserSubscriptMember(
                   in: symbol, args: indexArgs) == nil,
               let range = index.rangeValue,
               let relative = try interpretedIntegerIndexedCollectionRange(
                   range, relativeTo: selfValue) {
                let relativeArgs = CallArguments(arguments: [
                    .init(
                        label: indexArgs.arguments[0].label,
                        value: relative),
                ])
                if matchingUserSubscriptMember(
                    in: symbol, args: relativeArgs) != nil {
                    indexArgs = relativeArgs
                }
            }
            if let member = matchingUserSubscriptMember(
                in: symbol, args: indexArgs) {
                return chained(try relocating(call) {
                    try runUserSubscriptGetter(
                        member,
                        symbolName: symbol.name,
                        selfValue: selfValue,
                        args: indexArgs)
                })
            }
        }
        if let string = base.stringValue {
            // `text[range]` / `text[i]` with String.Index values.
            if let range = index.rangeValue {
                // A range subscript yields a Substring, and a Substring SHARES
                // its base's indices — `s[i...].startIndex` is `i`, and an
                // index the slice hands back is still valid in `s`. Copying it
                // into a fresh String re-bases those indices to zero, which
                // silently breaks every loop that walks a string by slicing
                // what is left and searching it (IceCubes' `URL.init(string:
                // encodePath:)` never terminates: `startIndex = endIndex`
                // assigns a slice-relative offset back into a base-relative
                // cursor, so the cursor oscillates instead of advancing).
                // Slice the receiver's OWN index space so nesting composes.
                let source = base.substringValue ?? string[...]
                return chained(.native(
                    source[try stringSlice(range, in: source, node: call)]))
            }
            if case .host(let indexAny) = index,
               let position = indexAny as? String.Index,
               position >= string.startIndex, position < string.endIndex {
                    return chained(.native(String(string[position])))
            }
        }
        // Library key-value stores with DECLARED defaults (sindresorhus/
        // Defaults: `Defaults[.windowSize]` with `Defaults.Keys.windowSize =
        // Key("…", default: NSSize(…))`): a fresh store answers the key's
        // declared default — the @Default-wrapper doctrine at subscript level.
        if let keyBag = try storeKeyBag(base: base, index: index),
           let declared = try readHostMember("default", on: keyBag)
               ?? readHostMember("defaultValue", on: keyBag) {
            return chained(declared)
        }
        if case .hostFunction(let subscripting)? = try nativeMember(
            "subscript", on: base) {
            var arguments: [CallArguments.Argument] = [
                .init(label: call.arguments.first?.label?.text, value: index),
            ]
            for argument in call.arguments.dropFirst() {
                arguments.append(.init(
                    label: argument.label?.text,
                    value: try evaluate(argument.expression, in: env)))
            }
            return chained(try relocating(call) {
                try subscripting.invoke(
                    CallArguments(arguments: arguments), self)
            })
        }
        if case .host(let any) = base,
           case .hostFunction(let subscripting)? = try readHostMember(
            "subscript", on: any) {
            // Host subscripts (AttributedString[range] styling proxies).
            let args = CallArguments(arguments: [.init(label: nil, value: index)])
            return chained(try relocating(call) { try subscripting.invoke(args, self) })
        }
        if case .host(let dataAny) = base, let bytes = dataAny as? Data {
            // Byte access and slices (bech32 decoders index raw buffers).
            if let i = index.intValue {
                guard i >= 0, i < bytes.count else {
                    throw error(call, "Data index \(i) out of range")
                }
                return chained(.native(
                    Int(bytes[bytes.index(bytes.startIndex, offsetBy: i)])))
            }
            if let range = index.rangeValue {
                let bounds = try integerSlice(range, count: bytes.count, name: "Data", node: call)
                let start = bytes.index(bytes.startIndex, offsetBy: bounds.lowerBound)
                let end = bytes.index(bytes.startIndex, offsetBy: bounds.upperBound)
                return chained(.native(Data(bytes[start..<end])))
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

    /// Bounds are resolved in the RECEIVER's index space, so this takes the
    /// slice view rather than a String: `Substring` and `String` share
    /// `String.Index`, and only the slice knows where its own bounds are.
    func stringSlice(
        _ range: RuntimeRangeValue,
        in string: Substring,
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
