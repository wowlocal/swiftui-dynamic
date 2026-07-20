import Foundation
import SwiftSyntax

nonisolated enum CoreFunctionIntrinsic: Sendable {
    case intConversion
    case integerMinimum
    case integerMaximum
    case taskType
}

extension Interpreter {
    // MARK: - Global builtins

    /// Parsed once per process, then shared by every interpreter session.
    /// HostFunction descriptors are immutable; reparsing these declarations
    /// for each of the corpus's hundreds of interpreters would turn a cached
    /// call contract into startup work.
    @MainActor private static let typedMathBuiltins: [String: HostFunction] = {
        @MainActor func typed(
            _ declaration: String,
            _ invoke: @escaping @MainActor
                (CallArguments, EvalContext) throws -> RuntimeValue
        ) -> HostFunction {
            do {
                return try HostFunction(declaration: declaration, invoke: invoke)
            } catch {
                preconditionFailure("invalid builtin declaration: \(error)")
            }
        }
        @MainActor func overloads(_ functions: [HostFunction]) -> HostFunction {
            do {
                return try HostFunction(overloads: functions)
            } catch {
                preconditionFailure("invalid builtin overload set: \(error)")
            }
        }

        var table: [String: HostFunction] = [:]
        let abs = overloads([
            typed("func abs(_ value: Int) -> Int") { args, _ in
                .native(Swift.abs(args.positional(0)!.intValue!))
            },
            typed("func abs(_ value: Double) -> Double") { args, _ in
                .native(Swift.abs(args.positional(0)!.doubleValue!))
            },
        ])
        table[abs.name] = abs

        let unary: [(String, @MainActor @Sendable (Double) -> Double)] = [
            ("round", { $0.rounded() }),
            ("floor", { $0.rounded(.down) }),
            ("ceil", { $0.rounded(.up) }),
            ("sqrt", { $0.squareRoot() }),
            ("sin", Foundation.sin),
            ("cos", Foundation.cos),
            ("tan", Foundation.tan),
            ("asin", Foundation.asin),
            ("acos", Foundation.acos),
            ("atan", Foundation.atan),
            ("log", Foundation.log),
            ("log2", Foundation.log2),
            ("exp", Foundation.exp),
        ]
        for (name, operation) in unary {
            table[name] = typed("func \(name)(_ value: Double) -> Double") {
                arguments, _ in
                .native(operation(arguments.positional(0)!.doubleValue!))
            }
        }
        table["atan2"] = typed(
            "func atan2(_ y: Double, _ x: Double) -> Double"
        ) { arguments, _ in
            .native(Foundation.atan2(
                arguments.positional(0)!.doubleValue!,
                arguments.positional(1)!.doubleValue!))
        }
        table["hypot"] = typed(
            "func hypot(_ x: Double, _ y: Double) -> Double"
        ) { arguments, _ in
            .native(Foundation.hypot(
                arguments.positional(0)!.doubleValue!,
                arguments.positional(1)!.doubleValue!))
        }
        table["pow"] = typed(
            "func pow(_ base: Double, _ exponent: Double) -> Double"
        ) { arguments, _ in
            .native(Foundation.pow(
                arguments.positional(0)!.doubleValue!,
                arguments.positional(1)!.doubleValue!))
        }
        return table
    }()

    func defineGlobalBuiltins() {
        func define(
            _ name: String,
            intrinsic: CoreFunctionIntrinsic? = nil,
            _ invoke: @escaping @MainActor
                (CallArguments, EvalContext) throws -> RuntimeValue
        ) {
            let function = HostFunction(name: name, invoke: invoke)
            if let intrinsic {
                registerCoreFunctionIntrinsic(intrinsic, for: function)
            }
            globals.define(name, .hostFunction(function))
        }
        define("print") { args, _ in
            Swift.print(args.arguments.map { $0.value.stringValue ?? $0.value.stringified }.joined(separator: " "))
            return .void
        }
        define("Task", intrinsic: .taskType) { args, context in
            if let body = args.firstUnlabeledClosure ?? args.closure(labeled: "operation") {
                let priority = try RuntimeTaskPriority.sourceValue(
                    args.labeled("priority"))
                if let sourceName = args.labeled("name") {
                    return try context.spawnBackgroundTask(
                        body,
                        arguments: [],
                        name: try RuntimeTaskName.sourceValue(sourceName),
                        priority: priority)
                }
                return try context.spawnBackgroundTask(
                    body,
                    arguments: [],
                    priority: priority)
            }
            if let hostValue = try context.invokeHostConstructor(named: "Task", arguments: args) {
                return hostValue
            }
            throw RuntimeError(message: "Task needs an operation closure")
        }
        globals.define(
            "AsyncStream",
            .hostFunction(sourceAsyncStreamFunction()))
        globals.define(
            "AsyncThrowingStream",
            .hostFunction(sourceAsyncThrowingStreamFunction()))
        for sourceName in GeneratedConcurrencySurface
                .topLevelFunctionDispatch.keys.sorted() {
            guard let intrinsic = GeneratedConcurrencySurface
                    .topLevelFunctionIntrinsic(named: sourceName) else {
                preconditionFailure(
                    "generated concurrency function lost its intrinsic")
            }
            let function: HostFunction
            if intrinsic == .unstructuredTask {
                function = sourceUnstructuredTaskFunction(name: sourceName)
            } else if intrinsic == .detachedTask {
                function = sourceDetachedTaskFunction(name: sourceName)
            } else if intrinsic == .withTaskCancellationHandler {
                function = sourceTaskCancellationHandlerFunction(
                    name: sourceName)
            } else if intrinsic == .withTaskPriorityEscalationHandler {
                function = sourceTaskPriorityEscalationHandlerFunction(
                    name: sourceName)
            } else if intrinsic == .withTaskExecutorPreference {
                function = sourceTaskExecutorPreferenceFunction(
                    name: sourceName)
            } else if intrinsic == .withCheckedContinuation {
                function = sourceCheckedContinuationFunction(
                    name: sourceName, allowsThrowingResume: false)
            } else if intrinsic == .withCheckedThrowingContinuation {
                function = sourceCheckedContinuationFunction(
                    name: sourceName, allowsThrowingResume: true)
            } else if intrinsic == .unsupportedUnsafeContinuation {
                function = sourceUnsupportedUnsafeContinuationFunction(
                    name: sourceName)
            } else if intrinsic == .extractIsolation {
                function = sourceExtractIsolationFunction(name: sourceName)
            } else if intrinsic == .withCurrentTaskCapability {
                function = sourceCurrentTaskCapabilityFunction(
                    name: sourceName)
            } else if let kind = RuntimeTaskGroupKind(
                functionIntrinsic: intrinsic
            ) {
                function = sourceTaskGroupFunction(kind: kind)
            } else {
                preconditionFailure(
                    "generated concurrency intrinsic has no runtime adapter")
            }
            precondition(function.name == sourceName,
                "generated concurrency function name drifted from its adapter")
            globals.define(sourceName, .hostFunction(function))
        }
        for (name, function) in Self.typedMathBuiltins {
            globals.define(name, .hostFunction(function))
        }
        define("NSLocalizedString") { args, _ in
            // No string tables headlessly: Foundation's own miss behavior —
            // the explicit value: when non-empty, otherwise the KEY.
            if let value = args.labeled("value")?.stringValue, !value.isEmpty {
                return .native(value)
            }
            return .native(args.positional(0)?.stringValue ?? "")
        }
        define("type") { args, _ in
            // `type(of: endpoint)` — the DYNAMIC metatype, comparable with
            // `X.self` (MastodonClient branches its URL path on it).
            guard let value = args.labeled("of") else {
                throw RuntimeError(message: "type(of:) needs a value")
            }
            switch value {
            case .instance(let instance): return .type(instance.symbol)
            case .enumCase(let enumCase): return .enumType(enumCase.symbol)
            case .type, .enumType: return value
            case .int: return .native(HostTypeMarker(name: "Int"))
            case .double: return .native(HostTypeMarker(name: "Double"))
            case .bool: return .native(HostTypeMarker(name: "Bool"))
            case .host(let any):
                return .native(HostTypeMarker(name: String(describing: Swift.type(of: any))))
            default:
                return .native(HostTypeMarker(name: "Void"))
            }
        }
        define("min", intrinsic: .integerMinimum) { args, _ in
            try Self.extremum(args, op: "<")
        }
        define("max", intrinsic: .integerMaximum) { args, _ in
            try Self.extremum(args, op: ">")
        }
        define("stride") { args, _ in
            guard let from = args.labeled("from"),
                  let by = args.labeled("by") else {
                throw RuntimeError(message: "stride(from:to/through:by:) needs bounds")
            }
            let to = args.labeled("to")
            let through = args.labeled("through")
            guard (to == nil) != (through == nil) else {
                throw RuntimeError(message: "stride needs exactly one of to: or through:")
            }

            if let start = from.intValue, let step = by.intValue,
               let end = (to ?? through)?.intValue {
                guard step != 0 else {
                    throw RuntimeError(message: "stride by: must not be zero")
                }
                if to != nil {
                    return .native(Swift.stride(
                        from: start, to: end, by: step).map(RuntimeValue.native))
                }
                return .native(Swift.stride(
                    from: start, through: end, by: step).map(RuntimeValue.native))
            }

            guard let start = from.doubleValue,
                  let step = by.doubleValue,
                  let end = (to ?? through)?.doubleValue,
                  step.isFinite, step != 0 else {
                throw RuntimeError(message: "stride bounds must be finite numeric values")
            }
            if to != nil {
                return .native(Swift.stride(
                    from: start, to: end, by: step).map(RuntimeValue.native))
            }
            return .native(Swift.stride(
                from: start, through: end, by: step).map(RuntimeValue.native))
        }
        define("String") { args, _ in
            if let format = args.labeled("format")?.stringValue {
                // `String(format: "%.1f", per)` — real formatting. Each
                // vararg must MATCH its directive's expectation: `%@`
                // dereferences an OBJECT pointer, so an Int riding under it
                // is a SIGSEGV (the NSLocalizedString("… %@ …") genre).
                let values = args.arguments.dropFirst().map(\.value)
                return .native(Self.cFormattedString(format, values: values))
            }
            if let repeating = args.labeled("repeating")?.stringValue, let count = args.labeled("count")?.intValue {
                return .native(Swift.String(repeating: repeating, count: Swift.max(0, count)))
            }
            if let bytes = args.labeled("bytes") {
                // String(bytes: data, encoding: .ascii) — real decode; NUL
                // padding trims (C buffers).
                if case .host(let any) = bytes, let data = any as? Data {
                    let text = String(decoding: data, as: UTF8.self)
                    return .some(
                        .native(String(text.prefix(while: { $0 != "\0" }))),
                        wrappedTypeName: "String")
                }
                if let text = bytes.stringValue {
                    return .some(.native(text), wrappedTypeName: "String")
                }
                return .none(wrappedTypeName: "String")
            }
            if args.labeled("cString") != nil || args.labeled("validatingUTF8") != nil {
                // C-string of an absorbed buffer reads empty (fresh).
                let value = args.labeled("cString") ?? args.labeled("validatingUTF8")
                return .native(value?.stringValue ?? "")
            }
            if let key = args.labeled("localized") {
                // `String(localized: "The Classic", bundle: .module,
                // comment: …)` — no string catalogs load headlessly, so the
                // KEY is the development-language value, exactly what an
                // unlocalized native run surfaces (FoodTruck's donut/city
                // names ride this).
                return .native(key.stringValue ?? key.stringified)
            }
            guard let value = args.positional(0) ?? args.labeled("describing") else { return .native("") }
            return .native(value.stringValue ?? value.stringified)
        }
        define("Dictionary") { args, ctx in
            // `Dictionary(uniqueKeysWithValues:)` / `Dictionary(grouping:by:)`
            // — the FoodTruck summaries genre. Bare `Dictionary()` is empty.
            if let pairs = args.labeled("uniqueKeysWithValues")?.arrayValue {
                var dict = DictValue()
                for pair in pairs {
                    if let tuple = pair.tupleValue, tuple.values.count == 2 {
                        try dict.update(
                            tuple.values[0], to: tuple.values[1],
                            by: ctx.collectionStorageValuesAreEqual)
                    }
                }
                return .native(dict)
            }
            if let elements = args.labeled("grouping")?.arrayValue,
               let by = args.closure(labeled: "by") {
                var dict = DictValue()
                for element in elements {
                    let key = try ctx.callClosure(by, arguments: [element])
                    var bucket = (try dict.lookup(
                        key, by: ctx.collectionStorageValuesAreEqual))
                        .arrayValue ?? []
                    bucket.append(element)
                    try dict.update(
                        key, to: .native(bucket),
                        by: ctx.collectionStorageValuesAreEqual)
                }
                return .native(dict)
            }
            return .native(DictValue())
        }
        for comparatorName in ["KeyPathComparator", "SortDescriptor"] {
            define(comparatorName) { args, _ in
                // `KeyPathComparator(\Order.status, order: .reverse)` — the
                // sorted(using:) carrier. Unknowable key paths still build a
                // comparator (identity order downstream).
                var stub = KeyPathStub(components: ["self"])
                if case .host(let any)? = args.positional(0), let real = any as? KeyPathStub {
                    stub = real
                }
                var ascending = true
                if case .implicitMember(let order)? = args.labeled("order"), order == "reverse" {
                    ascending = false
                }
                return .native(KeyPathComparatorBox(keyPath: stub, ascending: ascending))
            }
        }
        define("zip") { args, _ in
            // Stdlib zip over runtime sequences: pairs as unlabeled tuples,
            // so `for (index, subview) in zip(subviews.indices, subviews)`
            // destructures exactly like compiled Swift (FlowLayout's shape).
            @MainActor func sequenceElements(_ value: RuntimeValue?) -> [RuntimeValue] {
                guard let value else { return [] }
                if let array = value.arrayValue { return array }
                if case .range(let range) = value,
                   let lower = range.lowerBound?.intValue, let upper = range.upperBound?.intValue {
                    let top = range.includesUpperBound ? upper + 1 : upper
                    guard lower < top else { return [] }
                    return (lower..<top).map { .int($0) }
                }
                if let string = value.stringValue { return string.map { .string(String($0)) } }
                return []
            }
            let lefts = sequenceElements(args.positional(0))
            let rights = sequenceElements(args.positional(1))
            let pairs = Swift.zip(lefts, rights).map { left, right in
                RuntimeValue.native(TupleValue(labels: [nil, nil], values: [left, right]))
            }
            return .native(pairs)
        }
        define("srand48") { args, _ in
            // REAL libc seeding — the FoodTruck SeededRandomGenerator genre:
            // a constant-seeded drand48 stream matches native exactly.
            srand48(args.positional(0)?.intValue ?? 0)
            return .void
        }
        define("drand48") { [weak self] _, _ in
            let value = drand48()
            if ProcessInfo.processInfo.environment["RNG_TRACE"] != nil {
                Interpreter.rngDrawCount += 1
                let stack = self?.callStackNames.suffix(3).joined(separator: ">") ?? ""
                FileHandle.standardError.write(Data("DRAW \(Interpreter.rngDrawCount) \(value) [\(stack)]\n".utf8))
            }
            return .native(value)
        }
        define("UInt64") { args, _ in
            // Exact 64-bit carrier (interpreted next() overflows Int):
            // `UInt64(drand48() * Double(UInt64.max))` needs true UInt64.
            guard let value = args.positional(0) ?? args.labeled("bitPattern")
            else { return .native(UInt64(0) as Any) }
            if case .host(let any) = value,
               let pointer = any as? any HostRawMemoryCursor {
                return .native(UInt64(pointer.rawMemoryAddress) as Any)
            }
            if case .host(let any) = value, let u = any as? UInt64 { return .native(u) }
            if let d = value.doubleValue {
                return .native(UInt64(d.isFinite ? max(0, min(d, Double(UInt64.max))) : 0))
            }
            if let i = value.intValue { return .native(UInt64(max(0, i))) }
            return .native(UInt64(0))
        }
        define("Int", intrinsic: .intConversion) { args, _ in
            guard let value = args.positional(0) ?? args.labeled("exactly")
                ?? args.labeled("bitPattern") else {
                return .none(wrappedTypeName: "Int")
            }
            let exact = args.labeled("exactly") != nil
            if case .host(let any) = value,
               let pointer = any as? any HostRawMemoryCursor {
                guard pointer.rawMemoryAddress <= UInt(Int.max) else {
                    throw RuntimeError(message: "pointer address overflows Int.max")
                }
                return .native(Int(pointer.rawMemoryAddress))
            }
            if case .host(let any) = value, let u = any as? UInt64 {
                // Interpreted UInt64 carriers narrow when they fit (Int is
                // the value model); oversized reads throw like native traps.
                guard u <= UInt64(Int.max) else {
                    throw RuntimeError(message: "Int(\(u)) overflows Int.max")
                }
                let converted = RuntimeValue.native(Int(u))
                return exact ? converted.liftedToOptional(wrappedTypeName: "Int") : converted
            }
            if let i = value.intValue {
                let converted = RuntimeValue.native(i)
                return exact ? converted.liftedToOptional(wrappedTypeName: "Int") : converted
            }
            if let d = value.doubleValue {
                // Int(exactly:) is nil for fractional values — real semantics.
                if exact, d != d.rounded(.towardZero) {
                    return .none(wrappedTypeName: "Int")
                }
                guard d.isFinite, d >= Double(Int.min), d < 9223372036854775808.0 else {
                    throw RuntimeError(message: "Int(\(d)) overflows Int (native trap)")
                }
                let converted = RuntimeValue.native(Int(d))
                return exact ? converted.liftedToOptional(wrappedTypeName: "Int") : converted
            }
            if let s = value.stringValue {
                return .optional(Int(s).map(RuntimeValue.native), wrappedTypeName: "Int")
            }
            // Numeric conversion of an unknowable reads the fresh state —
            // Int(player.currentTime.truncatingRemainder(…)) is 0, not nil.
            if let z = Builtins.absorbedNumeric(value) { return .native(Int(z.isFinite ? z : 0)) }
            return .none(wrappedTypeName: "Int")
        }
        define("Double") { args, _ in
            guard let value = args.positional(0) ?? args.labeled("exactly") else {
                return .none(wrappedTypeName: "Double")
            }
            let exact = args.labeled("exactly") != nil
            if case .host(let any) = value, let u = any as? UInt64 {
                let converted = RuntimeValue.native(Double(u))
                return exact ? converted.liftedToOptional(wrappedTypeName: "Double") : converted
            }
            if let d = value.doubleValue {
                let converted = RuntimeValue.native(d)
                return exact ? converted.liftedToOptional(wrappedTypeName: "Double") : converted
            }
            if let s = value.stringValue {
                return .optional(
                    Double(s).map(RuntimeValue.native), wrappedTypeName: "Double")
            }
            if let z = Builtins.absorbedNumeric(value) { return .native(z) }
            return .none(wrappedTypeName: "Double")
        }
        define("TimeInterval") { args, _ in
            // TimeInterval IS Double (Foundation's typealias).
            guard let value = args.positional(0) ?? args.labeled("exactly") else { return .native(0.0) }
            let exact = args.labeled("exactly") != nil
            if let d = value.doubleValue {
                let converted = RuntimeValue.native(d)
                return exact
                    ? converted.liftedToOptional(wrappedTypeName: "Double")
                    : converted
            }
            if let s = value.stringValue {
                return .optional(
                    Double(s).map(RuntimeValue.native), wrappedTypeName: "Double")
            }
            if let z = Builtins.absorbedNumeric(value) {
                let converted = RuntimeValue.native(z)
                return exact
                    ? converted.liftedToOptional(wrappedTypeName: "Double")
                    : converted
            }
            if value.isNil {
                return exact ? .none(wrappedTypeName: "Double") : .native(0.0)
            }
            return .none(wrappedTypeName: "Double")
        }
        define("Float") { args, _ in
            // Our floating model is Double throughout.
            guard let value = args.positional(0) ?? args.labeled("exactly") else {
                return .none(wrappedTypeName: "Float")
            }
            let exact = args.labeled("exactly") != nil
            if let d = value.doubleValue {
                let converted = RuntimeValue.native(d)
                return exact
                    ? converted.liftedToOptional(wrappedTypeName: "Float")
                    : converted
            }
            if let s = value.stringValue {
                return .optional(
                    Double(s).map(RuntimeValue.native), wrappedTypeName: "Float")
            }
            if let z = Builtins.absorbedNumeric(value) {
                let converted = RuntimeValue.native(z)
                return exact
                    ? converted.liftedToOptional(wrappedTypeName: "Float")
                    : converted
            }
            return .none(wrappedTypeName: "Float")
        }
        define("CGFloat") { args, _ in
            // Our CGFloat model IS Double.
            let operand = args.positional(0) ?? args.labeled("exactly")
            let exact = args.labeled("exactly") != nil
            if let d = operand?.doubleValue {
                let converted = RuntimeValue.native(d)
                return exact
                    ? converted.liftedToOptional(wrappedTypeName: "CGFloat")
                    : converted
            }
            if let value = operand, let z = Builtins.absorbedNumeric(value) {
                let converted = RuntimeValue.native(z)
                return exact
                    ? converted.liftedToOptional(wrappedTypeName: "CGFloat")
                    : converted // unknowables read fresh zero (iter-94 rule)
            }
            // A NIL operand can't compile natively (the parameter is
            // non-optional) — it's an absorbed-environment artifact
            // (amperfy indexes a fresh-empty FFT array): fresh zero.
            if operand?.isNil == true {
                return exact ? .none(wrappedTypeName: "CGFloat") : .native(0.0)
            }
            throw RuntimeError(message: "CGFloat needs a number")
        }
        define("Array") { args, ctx in
            if let element = args.labeled("repeating"), let count = args.labeled("count")?.intValue {
                return .native([RuntimeValue](repeating: element, count: max(0, count)))
            }
            guard let value = args.positional(0) else { return .native([RuntimeValue]()) }
            if let range = value.rangeValue, let values = range.integerValues() { return .native(values) }
            if let collection = value.collectionElements {
                return .native(collection)
            }
            // Array("abc") splits into characters (single-char strings,
            // our character model): Array(constant)[i] indexes real chars.
            if let s = value.stringValue {
                return .native(s.map { RuntimeValue.native(String($0)) })
            }
            if let interpreter = ctx as? Interpreter,
               let collection = try interpreter
                .interpretedIntegerIndexedCollectionElements(value) {
                return .native(collection)
            }
            return .native([value])
        }
        define("Set") { args, ctx in
            let specializedElementType = args.labeled("__genericArguments")?
                .stringValue?.trimmingCharacters(in: .whitespaces)
            guard let value = args.positional(0) else {
                return .native(RuntimeSetValue(
                    elementTypeName: specializedElementType))
            }
            let elements: [RuntimeValue]
            if let collection = value.collectionElements {
                elements = collection
            } else if let range = value.rangeValue,
                      let integers = range.integerValues() {
                elements = integers
            } else if let string = value.stringValue {
                elements = string.map { .native(String($0)) }
            } else if let interpreter = ctx as? Interpreter,
                      let collection = try interpreter
                        .interpretedIntegerIndexedCollectionElements(value) {
                elements = collection
            } else {
                throw RuntimeError(message:
                    "Set needs a Sequence value, got \(ctx.hostTypeName(of: value)): "
                    + String(value.stringified.prefix(160)))
            }
            if let interpreter = ctx as? Interpreter {
                let elementType = specializedElementType
                    ?? value.setValue?.elementTypeName
                return .native(try interpreter.makeRuntimeSet(
                    elements, elementTypeName: elementType))
            }
            return .native(try RuntimeSetValue.deduplicating(
                elements, elementTypeName: specializedElementType,
                by: Builtins.areEqual))
        }
        define("fatalError") { args, _ in
            let message = args.positional(0)?.stringValue ?? "fatalError"
            throw RuntimeError(message: "fatalError: \(message)", fatal: true)
        }
        define("preconditionFailure") { args, _ in
            let message = args.positional(0)?.stringValue ?? "preconditionFailure"
            throw RuntimeError(message: "preconditionFailure: \(message)", fatal: true)
        }
        define("assertionFailure") { args, _ in
            let message = args.positional(0)?.stringValue ?? "assertionFailure"
            throw RuntimeError(message: "assertionFailure: \(message)", fatal: true)
        }
        // assert/precondition describe DEVICE truths: concrete false traps,
        // unknowable (marker-fed) conditions assume a healthy device.
        for trap in ["assert", "precondition"] {
            define(trap) { args, _ in
                if let concrete = args.positional(0)?.boolValue,
                   !concrete {
                    let message = args.positional(1)?.stringValue ?? trap
                    throw RuntimeError(message: "\(trap) failed: \(message)", fatal: true)
                }
                return .void
            }
        }
        // UInt64 is NOT in this list — it has a true 64-bit host carrier
        // above (the seeded-RNG genre needs exact UInt64).
        for intType in [
            "UInt", "UInt8", "UInt16", "UInt32",
            "Int8", "Int16", "Int32", "Int64",
        ] {
            define(intType) { args, _ in
                // Fixed-width conversions: our integer model is Int.
                let value = args.labeled("truncatingIfNeeded") ?? args.labeled("clamping")
                    ?? args.labeled("bitPattern") ?? args.labeled("exactly") ?? args.positional(0)
                if case .host(let any)? = value,
                   let pointer = any as? any HostRawMemoryCursor {
                    guard pointer.rawMemoryAddress <= UInt(Int.max) else {
                        throw RuntimeError(message:
                            "pointer address overflows interpreter integer storage")
                    }
                    return .native(Int(pointer.rawMemoryAddress))
                }
                if let i = value?.intValue { return .native(i) }
                if let d = value?.doubleValue {
                    // Clamp instead of native-trapping on out-of-Int doubles.
                    let clamped = d.isFinite ? Swift.max(Double(Int.min), Swift.min(d, 9223372036854775295.0)) : 0
                    return .native(Int(clamped))
                }
                if let s = value?.stringValue {
                    return .optional(
                        Int(s).map(RuntimeValue.native),
                        wrappedTypeName: intType)
                }
                if let value, let z = Builtins.absorbedNumeric(value) { return .native(Int(z.isFinite ? z : 0)) }
                return .native(0)
            }
        }
        define("Range") { args, _ in
            // Range(nsRange, in: string) — real conversion. An unknowable
            // NSRange (marker text-parse results) honestly fails: nil, the
            // parse that found nothing.
            if let text = (args.labeled("in"))?.stringValue {
                if case .host(let any)? = args.positional(0), let ns = any as? NSRange {
                    return .native(Range(ns, in: text))
                }
                return .none(wrappedTypeName: "Range<String.Index>")
            }
            return args.positional(0) ?? .nilValue
        }
        define("unsafeBitCast") { args, _ in
            // Bit-identity cast: the value passes through (casts are
            // optimistic everywhere in the interpreter).
            args.positional(0) ?? .void
        }
        define("UUID") { args, _ in
            // Real UUID semantics: uuidString parses (invalid → nil),
            // the argless form is a fresh random UUID.
            if let s = args.labeled("uuidString")?.stringValue {
                return .optional(
                    UUID(uuidString: s).map(RuntimeValue.native),
                    wrappedTypeName: "UUID")
            }
            return .native(UUID())
        }
        define("URL") { args, _ in
            // Real URL semantics: invalid strings are honestly nil.
            if let s = (args.labeled("string") ?? args.positional(0))?.stringValue {
                return .optional(
                    URL(string: s).map(RuntimeValue.native),
                    wrappedTypeName: "URL")
            }
            if let path = args.labeled("fileURLWithPath")?.stringValue {
                return .native(URL(fileURLWithPath: path))
            }
            // Unknowable string (host-constant markers like
            // UIApplication.openSettingsURLString): the URL is equally
            // unknowable but non-nil on device — the marker flows through.
            if let value = args.labeled("string") ?? args.positional(0), !value.isNil {
                return value
            }
            return .none(wrappedTypeName: "URL")
        }
        define("Date") { args, _ in
            // Interval inits construct for real; the argless form is `now`.
            if let interval = args.labeled("timeIntervalSince1970")?.doubleValue {
                return .native(Date(timeIntervalSince1970: interval))
            }
            if let interval = args.labeled("timeIntervalSinceNow")?.doubleValue {
                return .native(Date(timeIntervalSinceNow: interval))
            }
            if let interval = args.labeled("timeIntervalSinceReferenceDate")?.doubleValue {
                return .native(Date(timeIntervalSinceReferenceDate: interval))
            }
            if let interval = args.labeled("timeInterval")?.doubleValue,
               case .host(let any)? = args.labeled("since"), let since = any as? Date {
                return .native(Date(timeInterval: interval, since: since))
            }
            return .native(Date())
        }
    }

    /// Adapts interface-owned top-level spellings such as deprecated `async`
    /// to the same canonical runtime task record used by `Task.init`. The
    /// source spelling is generated metadata; task ownership, inheritance,
    /// priority, suspension, and outcome delivery remain one runtime path.
    private func sourceUnstructuredTaskFunction(name: String) -> HostFunction {
        HostFunction(name: name) { arguments, context in
            guard let operation = arguments.closure(labeled: "operation")
                    ?? arguments.firstUnlabeledClosure else {
                throw RuntimeError(message:
                    "\(name) needs an operation closure")
            }
            let priority = try RuntimeTaskPriority.sourceValue(
                arguments.labeled("priority"))
            // The explicit name slot selects canonical async-only creation
            // even though this API has no source `name:` parameter. Legacy
            // synchronous compatibility remains confined to the old Task
            // constructor entry points.
            return try context.spawnBackgroundTask(
                operation,
                arguments: [],
                name: nil,
                priority: priority)
        }
    }

    /// Adapts deprecated detached-task spellings to the same parentless,
    /// task-local-clearing runtime record used by `Task.detached`.
    private func sourceDetachedTaskFunction(name: String) -> HostFunction {
        HostFunction(name: name) { arguments, context in
            guard let operation = arguments.closure(labeled: "operation")
                    ?? arguments.firstUnlabeledClosure else {
                throw RuntimeError(message:
                    "\(name) needs an operation closure")
            }
            let priority = try RuntimeTaskPriority.sourceValue(
                arguments.labeled("priority"))
            // Selecting the name-aware face with an explicit nil keeps these
            // aliases on canonical async-only creation rather than legacy
            // synchronous Task.detached compatibility.
            return try context.spawnDetachedTask(
                operation,
                arguments: [],
                name: nil,
                priority: priority)
        }
    }

    private static func extremum(_ args: CallArguments, op: String) throws -> RuntimeValue {
        let values = args.arguments.map(\.value)
        guard var best = values.first else { throw RuntimeError(message: "min/max need arguments") }
        for value in values.dropFirst() {
            if try Builtins.binary(op, value, best).boolValue == true { best = value }
        }
        return best
    }
}
