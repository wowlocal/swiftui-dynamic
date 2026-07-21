import Foundation
import SwiftSyntax

/// Members on native values: arrays, strings, ranges, dictionaries, doubles.
/// This is the hand-written slice of the standard library that real SwiftUI
/// sample code leans on. Methods come back as bound `HostFunction`s so
/// `names.map { … }` works like any other call; closure-taking methods call
/// back through the `EvalContext`.
extension Interpreter {
    @MainActor private static let arrayFilterSignature: HostSignature = {
        do {
            return try HostSignature(parsing:
                "func Array.filter(_ isIncluded: (Any) throws -> Bool) rethrows -> [Any]")
        } catch {
            preconditionFailure(
                "invalid Array.filter host contract: \(error)")
        }
    }()

    @MainActor private static let stringAppendingSignature: HostSignature = {
        do {
            return try HostSignature(
                parsing: "func String.appending(_ other: String) -> String")
        } catch {
            preconditionFailure(
                "invalid String.appending host contract: \(error)")
        }
    }()

    /// Typed entry point for standard-library member dispatch. Keeping this
    /// separate from the host-`Any` fallback lets core values migrate to
    /// dedicated RuntimeValue storage without changing framework gateways.
    func nativeMember(
        _ name: String,
        on value: RuntimeValue,
        declaredTypeName: String? = nil
    ) throws -> RuntimeValue? {
        switch value.payload {
        case .array(let array):
            return try arrayMember(
                name,
                array,
                elementTypeName: RuntimeDeclaredType.arrayPayloadElementTypeName(
                    in: declaredTypeName))
        case .set(let set):
            return try setMember(name, set)
        case .optional(let optional):
            return optionalMember(name, optional)
        case .string(let string):
            return stringMember(name, string)
        case .tuple(let tuple):
            return tuple.value(for: name)
        case .integer(let integer):
            return try nativeMember(name, on: integer as Any)
        case .floatingPoint(let double):
            return try nativeMember(name, on: double as Any)
        case .boolean(let boolean):
            return try nativeMember(name, on: boolean as Any)
        case .dictionary(let dictionary):
            return try nativeMember(name, on: dictionary as Any)
        case .range(let range):
            return try nativeMember(name, on: range as Any)
        case .host(let host):
            return try nativeMember(name, on: host)
        default:
            return nil
        }
    }

    /// Standard-library Optional members operate on the wrapper itself. This
    /// is deliberately separate from optional chaining, which dispatches an
    /// arbitrary member onto the wrapped payload in `accessMember`.
    func optionalMember(
        _ name: String, _ optional: RuntimeOptionalValue
    ) -> RuntimeValue? {
        switch name {
        case "isNil": return .native(optional.wrapped == nil)
        case "isSome", "isNotNil": return .native(optional.wrapped != nil)
        case "unsafelyUnwrapped":
            return optional.wrapped ?? .none(wrappedTypeName: optional.wrappedTypeName)
        case "map", "flatMap":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                guard let wrapped = optional.wrapped else { return .none() }
                let mapped: RuntimeValue
                if let closure = args.closure(labeled: "transform")
                    ?? args.firstUnlabeledClosure ?? args.positional(0)?.closureValue {
                    mapped = try ctx.callClosure(closure, arguments: [wrapped])
                } else if case .hostFunction(let function)? = args.positional(0) {
                    mapped = try function.invoke(
                        CallArguments(arguments: [.init(label: nil, value: wrapped)]), ctx)
                } else {
                    throw RuntimeError(message: "Optional.\(name) needs a transform")
                }
                return name == "map" ? .some(mapped) : mapped.liftedToOptional()
            })
        default:
            return nil
        }
    }

    /// Convert the Sequence shapes accepted by Set's generic algebra.
    func setOperationElements(_ value: RuntimeValue) throws -> [RuntimeValue] {
        if let elements = value.collectionElements { return elements }
        if let range = value.rangeValue, let integers = range.integerValues() {
            return integers
        }
        if let string = value.stringValue {
            return string.map { .native(String($0)) }
        }
        throw RuntimeError(message: "Set operation needs a Sequence value")
    }

    /// Members whose result or semantics differ from Array. Sequence methods
    /// that genuinely return arrays delegate to the mature array path.
    private func setMember(
        _ name: String, _ set: RuntimeSetValue
    ) throws -> RuntimeValue? {
        let elements = set.elements
        switch name {
        case "count", "capacity": return .native(elements.count)
        case "isEmpty": return .native(elements.isEmpty)
        case "first":
            return .optional(elements.first, wrappedTypeName: set.elementTypeName)
        case "contains":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                if let closure = args.closure(labeled: "where")
                    ?? args.firstUnlabeledClosure {
                    for element in elements
                    where try ctx.callClosure(
                        closure, arguments: [element]).boolValue == true {
                        return .native(true)
                    }
                    return .native(false)
                }
                guard let target = args.positional(0) else {
                    throw RuntimeError(message: "Set.contains needs a value or closure")
                }
                if let self {
                    return .native(try set.contains(
                        target, by: self.collectionStorageValuesAreEqual))
                }
                return .native(try set.contains(target, by: Builtins.areEqual))
            })
        case "union", "intersection", "subtracting", "symmetricDifference":
            return .hostFunction(HostFunction(name: name) { [weak self] args, _ in
                guard let self, let otherValue = args.positional(0) else {
                    throw RuntimeError(message: "Set.\(name) needs a sequence")
                }
                let other = try self.setOperationElements(otherValue)
                let result: RuntimeSetValue
                switch name {
                case "union":
                    result = try set.union(
                        other, by: self.collectionStorageValuesAreEqual)
                case "intersection":
                    result = try set.intersection(
                        other, by: self.collectionStorageValuesAreEqual)
                case "subtracting":
                    result = try set.subtracting(
                        other, by: self.collectionStorageValuesAreEqual)
                default:
                    result = try set.symmetricDifference(
                        other, by: self.collectionStorageValuesAreEqual)
                }
                return .native(result)
            })
        case "isSubset", "isStrictSubset", "isSuperset", "isStrictSuperset", "isDisjoint":
            return .hostFunction(HostFunction(name: name) { [weak self] args, _ in
                guard let self,
                      let otherValue = args.labeled("of")
                        ?? args.labeled("with") ?? args.positional(0) else {
                    throw RuntimeError(message: "Set.\(name) needs a set")
                }
                let other = try self.setOperationElements(otherValue)
                let otherSet = try self.makeRuntimeSet(other)
                let allLeftInRight = try elements.allSatisfy {
                    try otherSet.contains(
                        $0, by: self.collectionStorageValuesAreEqual)
                }
                let allRightInLeft = try otherSet.elements.allSatisfy {
                    try set.contains(
                        $0, by: self.collectionStorageValuesAreEqual)
                }
                switch name {
                case "isSubset": return .native(allLeftInRight)
                case "isStrictSubset":
                    return .native(allLeftInRight && elements.count < otherSet.elements.count)
                case "isSuperset": return .native(allRightInLeft)
                case "isStrictSuperset":
                    return .native(allRightInLeft && elements.count > otherSet.elements.count)
                default:
                    return .native(try elements.allSatisfy {
                        try !otherSet.contains(
                            $0, by: self.collectionStorageValuesAreEqual)
                    })
                }
            })
        case "filter":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let closure = try Self.requiredClosure(args, name)
                var kept: [RuntimeValue] = []
                for element in elements
                where try ctx.callClosure(
                    closure, arguments: [element]).boolValue == true {
                    kept.append(element)
                }
                return .native(RuntimeSetValue(
                    uniqueElements: kept,
                    elementTypeName: set.elementTypeName))
            })
        case "map", "compactMap", "flatMap", "allSatisfy", "forEach",
             "reduce", "sorted", "elementsEqual", "min", "max",
             "randomElement", "prefix", "suffix", "dropFirst", "dropLast",
             "enumerated", "shuffled":
            return try arrayMember(name, elements)
        default:
            return nil
        }
    }

    /// Returns nil when the name is unknown, so the caller can try other routes
    /// (e.g. view modifiers) before erroring.
    ///
    /// This is the compatibility path for opaque framework values. Swift-shaped
    /// values enter through the RuntimeValue overload above.
    func nativeMember(_ name: String, on any: Any) throws -> RuntimeValue? {
        if let sequence = any as? any RuntimeMaterializedSequence {
            return try arrayMember(name, sequence.runtimeMaterializedElements)
        }
        if let buffer = any as? any RuntimeCollectionBackedBufferCarrier {
            switch name {
            case "count":
                return .native(buffer.runtimeElements.count)
            case "isEmpty":
                return .native(buffer.runtimeElements.isEmpty)
            case "baseAddress":
                return buffer.runtimeBaseAddressValue()
            default:
                break
            }
        }
        if let pointer = any as? any RuntimeCollectionBackedPointerCursor {
            switch name {
            case "advanced":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let distance = (args.labeled("by")
                        ?? args.positional(0))?.intValue else {
                        throw EvalMessage(
                            text: "advanced(by:) needs an integer")
                    }
                    return pointer.runtimeAdvancedValue(by: distance)
                })
            case "pointee":
                return try pointer.runtimePointeeValue()
            default:
                break
            }
        }
        if let pointer = any as? any RuntimeBulkWritablePointerCursor,
           let labels = GeneratedUnsafeMemorySurface
            .pointerBulkCopyLabels(for: name) {
            return .hostFunction(HostFunction(name: name) { args, _ in
                let sourceArgument = labels.source.isEmpty
                    ? args.positional(0)
                    : args.labeled(labels.source) ?? args.positional(0)
                let countArgument = labels.count.isEmpty
                    ? args.positional(1)
                    : args.labeled(labels.count) ?? args.positional(1)
                guard case .host(let sourcePayload)? = sourceArgument,
                      let source = sourcePayload
                        as? any RuntimeIntegerSubscriptReadable,
                      let count = countArgument?.intValue else {
                    throw EvalMessage(
                        text: "\(name) needs a readable pointer and an "
                            + "integer count")
                }
                try pointer.runtimeCopy(from: source, count: count)
                return .void
            })
        }
        if let buffer = any as? RuntimeCollectionBackedBuffer {
            if let label = GeneratedUnsafeMemorySurface
                .bufferRebindingMetatypeLabel(for: name) {
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let typeName = RuntimeMetatype.name(
                        of: args.labeled(label) ?? args.positional(0)) else {
                        throw EvalMessage(
                            text: "memory binding needs a scalar metatype")
                    }
                    return .native(try buffer.bindingMemory(to: typeName))
                })
            }
            return try arrayMember(
                name, buffer.elements,
                elementTypeName: buffer.elementTypeName)
        }
        if let pointer = any as? RuntimeCollectionBackedPointer {
            switch name {
            case "load":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let metatype = args.labeled("as") ?? args.positional(0)
                    else {
                        throw EvalMessage(text: "load(as:) needs a scalar metatype")
                    }
                    guard let typeName = RuntimeMetatype.name(of: metatype) else {
                        throw EvalMessage(text: "load(as:) needs a scalar metatype")
                    }
                    return try pointer.loadedValue(typeName: typeName)
                })
            default:
                return nil
            }
        }
        if let group = any as? RuntimeTaskGroup {
            return try sourceTaskGroupMember(name, on: group)
        }
        if let iterator = any as? RuntimeTaskGroupIterator {
            return try sourceTaskGroupIteratorMember(name, on: iterator)
        }
        if any is RuntimeActorIsolationValue,
           GeneratedConcurrencySurface.knowsNominalMember(
            typeName: "MainActor", memberName: name
           ) {
            throw RuntimeError(message:
                "MainActor.\(name) is declared by the active "
                    + "_Concurrency.swiftinterface but is not supported "
                    + "on the runtime MainActor isolation value")
        }
        if let task = any as? RuntimeUnsafeCurrentTask {
            switch GeneratedConcurrencySurface.nominalMemberIntrinsic(
                typeName: "UnsafeCurrentTask", memberName: name
            ) {
            case .currentTaskIsCancelled:
                return .native(try task.isCancelled())
            case .currentTaskPriority:
                return .native(try task.priority())
            case .currentTaskBasePriority:
                return .native(try task.basePriority())
            case .currentTaskCancel:
                return .hostFunction(HostFunction(name: name) { _, _ in
                    try task.cancel()
                    return .void
                })
            case .currentTaskHashValue:
                return .native(try task.identityHashValue())
            case .currentTaskIdentityEquals:
                // `==` enters through the interpreter's operator evaluator;
                // RuntimeUnsafeCurrentTask consults this generated route from
                // its HostRuntimeEquatable implementation.
                return nil
            case .mainActorRun:
                // Intrinsics are nominal-scoped; this branch handles only a
                // RuntimeUnsafeCurrentTask receiver. Generator/runtime drift
                // must fail closed rather than degrade to dynamic lookup.
                throw RuntimeError(message:
                    "generated MainActor.run intrinsic was selected for "
                        + "UnsafeCurrentTask")
            case nil:
                if GeneratedConcurrencySurface.knowsNominalMember(
                    typeName: "UnsafeCurrentTask", memberName: name
                ) {
                    throw RuntimeError(message:
                        "UnsafeCurrentTask.\(name) is declared by the active "
                            + "_Concurrency.swiftinterface but is not supported yet")
                }
                return nil
            }
        }
        if let priority = any as? RuntimeTaskPriority {
            switch name {
            case "rawValue":
                return .native(Int(priority.rawValue))
            default:
                return nil
            }
        }
        if let handle = any as? RuntimeTaskHandle {
            switch GeneratedConcurrencySurface.taskInstanceIntrinsic(
                memberName: name
            ) {
            case .cancel:
                return .hostFunction(HostFunction(name: name) { _, _ in
                    handle.cancel()
                    return .void
                })
            case .isCancelled:
                return .native(handle.isCancelled)
            case .value, .result:
                throw RuntimeError(message: "Task.\(name) requires await")
            case nil:
                break
            }
            switch name {
            case "isCompleted":
                return .native(handle.isCompleted)
            case "state":
                return .native(handle.state.rawValue)
            case "failureDescription":
                return .native(handle.failureDescription)
            default:
                if GeneratedConcurrencySurface.knowsTaskInstanceMember(name) {
                    throw RuntimeError(message:
                        "Task.\(name) is declared by the active "
                            + "_Concurrency.swiftinterface but is not supported yet")
                }
                return nil
            }
        }
        if let result = any as? RuntimeResultValue {
            switch name {
            case "get":
                return .hostFunction(HostFunction(name: name) { _, _ in
                    switch result.outcome {
                    case .success(let value, _):
                        return value
                    case .failure(let value, _):
                        if case .host(let payload) = value,
                           let error = payload as? Error {
                            throw error
                        }
                        throw InterpretedThrow(value: value)
                    }
                })
            default:
                return nil
            }
        }
        if let array = any as? [RuntimeValue] {
            return try arrayMember(name, array)
        }
        if let range = any as? RuntimeRangeValue {
            switch name {
            case "lowerBound": return range.lowerBound
            case "upperBound": return range.upperBound
            case "isEmpty": return .native(try range.isEmpty())
            case "contains":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let value = args.positional(0) else { return .native(false) }
                    return .native(try range.contains(value))
                })
            default:
                // Only integer ranges are Collections. Other bound domains
                // expose RangeExpression members without fake iteration.
                guard let values = range.integerValues() else { return nil }
                return try arrayMember(name, values)
            }
        }
        if let string = any as? String {
            return stringMember(name, string)
        }
        if let blob = any as? EncodedValueBlob {
            switch name {
            case "write":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    if let target = args.labeled("to") ?? args.positional(0) {
                        // Real URLs key by path; unknowable chain-URLs key
                        // by their stable stringified form.
                        if case .host(let urlAny) = target, let url = urlAny as? URL {
                            self.registry?.storeBlob(.native(blob), at: url.path)
                        } else {
                            self.registry?.storeBlob(.native(blob), at: target.stringified)
                        }
                    }
                    return .void
                })
            case "count": return .native(1)
            default: return nil
            }
        }
        if let data = any as? Data {
            switch name {
            case "withUnsafeBytes", "withUnsafeMutableBytes":
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(ChainedImplicitCall(
                        base: .implicitMember(name), member: "result", arguments: CallArguments()))
                })
            case "utf8", "bytes":
                // Byte view (damus reads .utf8.count off values that are
                // Data by the time they arrive) — Int array.
                return .native(data.map { RuntimeValue.native(Int($0)) })
            case "count": return .native(data.count)
            case "isEmpty": return .native(data.isEmpty)
            case "base64EncodedString":
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(data.base64EncodedString())
                })
            case "copyBytes":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard case .host(let target)? =
                            args.labeled("to") ?? args.positional(0),
                          let memory = target as? HostRawMemory else {
                        throw RuntimeError(message:
                            "Data.copyBytes(to:) needs writable host memory")
                    }
                    let requested = args.labeled("count")?.intValue
                        ?? args.positional(1)?.intValue ?? data.count
                    try memory.writeBytes(data, count: max(0, min(requested, data.count)))
                    return .void
                })
            default: return nil
            }
        }
        if let uuid = any as? UUID {
            switch name {
            case "uuidString", "description": return .native(uuid.uuidString)
            default: return nil
            }
        }
        if let url = any as? URL {
            switch name {
            case "path": return .native(url.path)
            case "absoluteString": return .native(url.absoluteString)
            case "lastPathComponent": return .native(url.lastPathComponent)
            case "pathExtension": return .native(url.pathExtension)
            case "appending":
                // Modern forms: appending(path:) / appending(component:).
                return .hostFunction(HostFunction(name: name) { args, _ in
                    if let path = (args.labeled("path") ?? args.labeled("component"))?.stringValue {
                        return .native(url.appendingPathComponent(path))
                    }
                    return .native(url) // queryItems etc. — unchanged base
                })
            case "appendingPathComponent":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let component = args.positional(0)?.stringValue else {
                        // Unknowable component: the resulting URL is equally
                        // unknowable (absorbs downstream).
                        return .native(ChainedImplicitCall(
                            base: .native(url), member: name, arguments: args))
                    }
                    return .native(url.appendingPathComponent(component))
                })
            case "appendingPathExtension":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let ext = args.positional(0)?.stringValue else {
                        throw RuntimeError(message: "appendingPathExtension needs a string")
                    }
                    return .native(url.appendingPathExtension(ext))
                })
            case "deletingLastPathComponent":
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(url.deletingLastPathComponent())
                })
            case "deletingPathExtension":
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(url.deletingPathExtension())
                })
            default: return nil
            }
        }
        if let indexRange = any as? Range<String.Index> {
            switch name {
            case "lowerBound": return .native(indexRange.lowerBound)
            case "upperBound": return .native(indexRange.upperBound)
            case "isEmpty": return .native(indexRange.isEmpty)
            default: return nil
            }
        }
        if let dict = any as? DictValue {
            switch name {
            case "count": return .native(dict.count)
            case "isEmpty": return .native(dict.isEmpty)
            // Foundation exposes the same collection as `NSDictionary.allKeys`.
            // JSONSerialization is bridged into DictValue, so preserve that
            // Foundation spelling instead of leaking the runtime representation.
            case "keys", "allKeys": return .native(dict.keys)
            case "values": return .native(dict.values)
            case "isEqual":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let other = args.positional(0) else {
                        return .native(false)
                    }
                    return .native(try Builtins.areEqual(.native(dict), other))
                })
            case "contains":
                // Dictionary's only contains is the PREDICATE form; the
                // element is the native (key:, value:) labeled tuple.
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    guard let predicate = args.closure(labeled: "where") ?? args.firstUnlabeledClosure else {
                        throw RuntimeError(message: "Dictionary.contains needs a where: predicate")
                    }
                    for (key, value) in zip(dict.keys, dict.values) {
                        let element = RuntimeValue.native(
                            TupleValue(labels: ["key", "value"], values: [key, value]))
                        if try ctx.callClosure(predicate, arguments: [element]).boolValue == true {
                            return .native(true)
                        }
                    }
                    return .native(false)
                })
            case "filter":
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    guard let predicate = args.firstUnlabeledClosure ?? args.closure(labeled: "isIncluded") else {
                        throw RuntimeError(message: "Dictionary.filter needs a predicate")
                    }
                    var keys: [RuntimeValue] = []
                    var values: [RuntimeValue] = []
                    for (key, value) in zip(dict.keys, dict.values) {
                        let element = RuntimeValue.native(
                            TupleValue(labels: ["key", "value"], values: [key, value]))
                        if try ctx.callClosure(predicate, arguments: [element]).boolValue == true {
                            keys.append(key)
                            values.append(value)
                        }
                    }
                    return .native(DictValue(keys: keys, values: values))
                })
            case "compactMap":
                return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                    var out: [RuntimeValue] = []
                    for (key, value) in zip(dict.keys, dict.values) {
                        let element = RuntimeValue.native(
                            TupleValue(labels: ["key", "value"], values: [key, value]))
                        let mapped = try Self.mapStep(
                            args, name, element, nil, self, ctx)
                        if let unwrapped = mapped.unwrappedOptionalOrSelf {
                            out.append(unwrapped)
                        }
                    }
                    return .native(out)
                })
            case "map":
                // `dataSource.map(\.key)` — keypath transforms apply to the
                // (key:, value:) pair like any SE-0249 function position.
                return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                    .native(try zip(dict.keys, dict.values).map { key, value in
                        try Self.mapStep(args, name, .native(
                            TupleValue(labels: ["key", "value"], values: [key, value])),
                            nil, self, ctx)
                    })
                })
            case "sorted":
                // Dictionary.sorted(by:) — pairs compared as (key:, value:)
                // elements; the result is the native array-of-tuples.
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    guard let areInOrder = args.closure(labeled: "by") ?? args.firstUnlabeledClosure else {
                        throw RuntimeError(message: "Dictionary.sorted needs a by: predicate")
                    }
                    let pairs = zip(dict.keys, dict.values).map { key, value in
                        RuntimeValue.native(TupleValue(labels: ["key", "value"], values: [key, value]))
                    }
                    var sorted = pairs
                    // Insertion sort via the interpreted predicate (throwing
                    // comparators can't ride Swift's sort(by:)).
                    for index in 1..<max(sorted.count, 1) {
                        var cursor = index
                        while cursor > 0,
                              try ctx.callClosure(
                                  areInOrder,
                                  arguments: [sorted[cursor], sorted[cursor - 1]]).boolValue == true {
                            sorted.swapAt(cursor, cursor - 1)
                            cursor -= 1
                        }
                    }
                    return .native(sorted)
                })
            case "enumerated":
                // `for (_, value) in params.enumerated()` (the APIService
                // genre): (offset, (key:, value:)) pairs, so `value.key` /
                // `value.value` read through the inner labeled tuple.
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(zip(dict.keys, dict.values).enumerated().map { index, pair in
                        RuntimeValue.native(TupleValue(labels: [nil, nil], values: [
                            .native(index),
                            .native(TupleValue(labels: ["key", "value"], values: [pair.0, pair.1])),
                        ]))
                    })
                })
            default: return nil
            }
        }
        if let int = any as? Int, name == "truncatingRemainder" || name == "remainder"
            || name == "rounded" || name == "isZero" || name == "isFinite"
            || name == "isInfinite" || name == "isNaN" || name == "isNormal" {
            // Interpreted math sometimes lands on Int where the source had a
            // floating value (bridge numbers are Doubles) — promote.
            return try nativeMember(name, on: Double(int))
        }
        if let double = any as? Double {
            switch name {
            case "rounded":
                return .hostFunction(HostFunction(name: name) { _, _ in .native(double.rounded()) })
            case "isZero": return .native(double.isZero)
            case "isFinite": return .native(double.isFinite)
            case "isInfinite": return .native(double.isInfinite)
            case "isNaN": return .native(double.isNaN)
            case "isNormal": return .native(double.isNormal)
            case "remainder":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let divisor = (args.labeled("dividingBy") ?? args.positional(0))?.doubleValue else {
                        throw RuntimeError(message: "remainder(dividingBy:) needs a number")
                    }
                    return .native(double.remainder(dividingBy: divisor))
                })
            case "truncatingRemainder":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let divisor = (args.labeled("dividingBy") ?? args.positional(0))?.doubleValue else {
                        throw RuntimeError(message: "truncatingRemainder(dividingBy:) needs a number")
                    }
                    return .native(double.truncatingRemainder(dividingBy: divisor))
                })
            default: return nil
            }
        }
        if let uuid = any as? UUID {
            switch name {
            case "uuidString": return .native(uuid.uuidString)
            default: return nil
            }
        }
        if let date = any as? Date {
            switch name {
            case "formatted":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    if args.isEmpty { return .native(date.formatted()) }
                    return .native(date.formatted(
                        date: Self.dateStyle(args.labeled("date")),
                        time: Self.timeStyle(args.labeled("time"))
                    ))
                })
            case "timeIntervalSince1970": return .native(date.timeIntervalSince1970)
            case "timeIntervalSinceReferenceDate": return .native(date.timeIntervalSinceReferenceDate)
            case "addingTimeInterval":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let interval = args.positional(0)?.doubleValue else {
                        throw RuntimeError(message: "addingTimeInterval needs a number")
                    }
                    return .native(date.addingTimeInterval(interval))
                })
            default: return nil
            }
        }
        return nil
    }

    private func arrayMember(
        _ name: String,
        _ array: [RuntimeValue],
        elementTypeName: String? = nil
    ) throws -> RuntimeValue? {
        if let generated = GeneratedCollectionDefaultSurface
            .nativeIndexMotionMember(
                named: name, receiver: .native(array)) {
            return .hostFunction(generated)
        }
        if let generated = GeneratedCollectionDefaultSurface
            .nativeIndexSearchMember(
                named: name, receiver: .native(array)) {
            return .hostFunction(generated)
        }
        switch name {
        case "count": return .native(array.count)
        case "isEmpty": return .native(array.isEmpty)
        case "first":
            return .optional(
                array.first, wrappedTypeName: elementTypeName)
        case "last":
            return .optional(
                array.last, wrappedTypeName: elementTypeName)
        case "indices": return .native(0..<array.count)
        case "startIndex": return .native(0)
        case "endIndex": return .native(array.count)
        case "elementsEqual":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let other = args.positional(0)?.arrayValue, other.count == array.count else {
                    return .native(false)
                }
                for (a, b) in zip(array, other) where try !Builtins.areEqual(a, b) {
                    return .native(false)
                }
                return .native(true)
            })
        case "withContiguousStorageIfAvailable":
            // The interpreter owns value arrays, not a stable addressable
            // buffer. This API is explicitly a capability query: returning
            // nil makes source execute its declared collection fallback
            // instead of treating an absorbing pointer marker as success.
            return .hostFunction(HostFunction(name: name) { _, _ in
                .none()
            })
        case "withUnsafeBufferPointer":
            // The immutable carrier retains both values and their declared
            // element ABI, so a source buffer stored after this callback can
            // keep safe collection-backed pointer semantics without leaking
            // the callback's temporary machine address.
            return .hostFunction(HostFunction(name: name) { args, context in
                let body = try Self.requiredClosure(args, name)
                return try context.callClosure(
                    body, arguments: [
                        .native(RuntimeCollectionBackedBuffer(
                            array, elementTypeName: elementTypeName)),
                    ])
            })
        case "baseAddress":
            // A materialized read-only buffer intentionally exposes no raw
            // address. Source pointer fast paths then execute their declared
            // scalar fallback; only the scoped buffer proxy above can mint a
            // collection-backed pointer during construction.
            return .none(wrappedTypeName: "UnsafePointer")

        case "flatMap":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                var out: [RuntimeValue] = []
                for element in array {
                    let mapped = try Self.mapStep(
                        args, name, element, elementTypeName, self, ctx)
                    if let nested = mapped.arrayValue {
                        out.append(contentsOf: nested)
                    } else if !mapped.isNil {
                        out.append(mapped)
                    }
                }
                return .native(out)
            })
        case "map", "compactMap":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                var out: [RuntimeValue] = []
                for element in array {
                    let mapped = try Self.mapStep(
                        args, name, element, elementTypeName, self, ctx)
                    if name == "compactMap" {
                        guard let unwrapped = mapped.unwrappedOptionalOrSelf else { continue }
                        out.append(unwrapped)
                    } else {
                        out.append(mapped)
                    }
                }
                return .native(out)
            })
        case "filter":
            do {
                return .hostFunction(try HostFunction(
                    signature: Self.arrayFilterSignature
                ) { [weak self] args, ctx in
                    var out: [RuntimeValue] = []
                    for element in array
                    where try Self.mapStep(
                        args, name, element, elementTypeName, self, ctx
                    ).boolValue == true {
                        out.append(element)
                    }
                    return .native(out)
                })
            } catch {
                preconditionFailure(
                    "invalid Array.filter host gateway: \(error)")
            }
        case "allSatisfy":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                for element in array
                where try Self.mapStep(
                    args, name, element, elementTypeName, self, ctx
                ).boolValue != true {
                    return .native(false)
                }
                return .native(true)
            })
        case "allSatisfy":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                for element in array
                where try Self.mapStep(
                    args, name, element, elementTypeName, self, ctx
                ).boolValue != true {
                    return .native(false)
                }
                return .native(true)
            })
        case "forEach":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let closure = try Self.requiredClosure(args, name)
                for element in array {
                    _ = try ctx.callClosure(closure, arguments: [element])
                }
                return .void
            })
        case "reduce":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                // `reduce(into: [:]) { acc, el in … }` — pass a real inout
                // box so value-backed accumulators copy in and out just like
                // the standard library implementation.
                if var into = args.labeled("into") {
                    // A marker seed (`reduce(into: .empty)`) resolves against
                    // the ambient expected type — the enclosing return
                    // annotation, exactly where native inference reads it.
                    if case .implicitMember = into,
                       let interpreter = ctx as? Interpreter,
                       let hint = interpreter.expectedAnnotationStack.last {
                        into = try interpreter.resolveAnnotated(into, typeName: hint)
                    }
                    let closure = try Self.requiredClosure(args, name)
                    let accumulator = Box(into)
                    for element in array {
                        let slot = InoutSlot(box: accumulator, target: nil, current: accumulator.value)
                        _ = try ctx.callClosure(closure, arguments: [.native(slot), element])
                    }
                    return accumulator.value
                }
                guard let initial = args.positional(0) else {
                    throw RuntimeError(message: "reduce needs an initial value")
                }
                // The accumulator may ITSELF be a closure (SwiftUIFlux folds
                // middleware into a dispatch function) — the combiner is the
                // second/trailing argument, never the initial value.
                let combineArgs = CallArguments(arguments: Array(args.arguments.dropFirst()))
                let call = try Self.requiredCallable(combineArgs, name)
                var accumulator = initial
                for element in array {
                    accumulator = try call(ctx, [accumulator, element])
                }
                return accumulator
            })
        case "sorted":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                if let usingValue = args.labeled("using") {
                    // `sorted(using: [KeyPathComparator(...)])` — key-path
                    // values compare per comparator, earlier comparators win.
                    var comparators: [KeyPathComparatorBox] = []
                    if let list = usingValue.arrayValue {
                        for entry in list {
                            if case .host(let a) = entry, let box = a as? KeyPathComparatorBox {
                                comparators.append(box)
                            }
                        }
                    } else if case .host(let a) = usingValue, let box = a as? KeyPathComparatorBox {
                        comparators.append(box)
                    }
                    guard !comparators.isEmpty, let interpreter = ctx as? Interpreter else {
                        return .native(array) // unknowable comparator: input order
                    }
                    var failure: Error?
                    let out = array.sorted { a, b in
                        if failure != nil { return false }
                        do {
                            for comparator in comparators {
                                let left = try interpreter.applyKeyPath(comparator.keyPath, to: a)
                                let right = try interpreter.applyKeyPath(comparator.keyPath, to: b)
                                if try Builtins.areEqual(left, right) { continue }
                                let less = try interpreter.evaluateBinary("<", left, right).boolValue == true
                                return comparator.ascending ? less : !less
                            }
                            return false
                        } catch { failure = error; return false }
                    }
                    if let failure { throw failure }
                    return .native(out)
                }
                if let call = try? Self.requiredCallable(args, name) {
                    var failure: Error?
                    let out = array.sorted { a, b in
                        if failure != nil { return false }
                        do { return try call(ctx, [a, b]).boolValue == true }
                        catch { failure = error; return false }
                    }
                    if let failure { throw failure }
                    return .native(out)
                }
                var failure: Error?
                let out = array.sorted { a, b in
                    if failure != nil { return false }
                    do {
                        if let interpreter = ctx as? Interpreter {
                            return try interpreter.evaluateBinary("<", a, b).boolValue == true
                        }
                        return try Builtins.binary("<", a, b).boolValue == true
                    }
                    catch { failure = error; return false }
                }
                if let failure { throw failure }
                return .native(out)
            })
        case "contains":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                if let closure = args.closure(labeled: "where") ?? args.firstUnlabeledClosure {
                    for element in array where try ctx.callClosure(closure, arguments: [element]).boolValue == true {
                        return .native(true)
                    }
                    return .native(false)
                }
                guard let target = args.positional(0) else {
                    throw RuntimeError(message: "contains needs a value or a closure")
                }
                for element in array where try Builtins.areEqual(element, target) {
                    return .native(true)
                }
                return .native(false)
            })
        case "joined":
            return .hostFunction(HostFunction(name: name) { args, _ in
                let separator = args.labeled("separator")?.stringValue ?? ""
                let strings = array.map { $0.stringValue ?? $0.stringified }
                return .native(strings.joined(separator: separator))
            })
        case "reversed":
            return .hostFunction(HostFunction(name: name) { _, _ in .native(Array(array.reversed())) })
        case "shuffled":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                // `shuffled(using: &generator)` — the real Fisher-Yates over
                // the interpreted generator (seeded-stream parity).
                if let interpreter = ctx as? Interpreter,
                   let generator = interpreter.generatorInstance(from: args.labeled("using")) {
                    var proxy = InterpretedGeneratorProxy(interpreter: interpreter, generator: generator)
                    return .native(array.shuffled(using: &proxy))
                }
                return .native(array.shuffled())
            })
        case "prefix", "suffix", "dropFirst", "dropLast":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                // The count is Int-POSITION: implicit markers resolve here
                // (`prefix(.random(in: 1...5, using: &generator))` — the
                // Kit's order generator).
                var count = args.positional(0)?.intValue
                if count == nil, let raw = args.positional(0),
                   let interpreter = ctx as? Interpreter {
                    count = (try? interpreter.resolveAnnotated(raw, typeName: "Int"))?.intValue
                }
                switch name {
                case "prefix": return .native(Array(array.prefix(count ?? array.count)))
                case "suffix": return .native(Array(array.suffix(count ?? array.count)))
                case "dropFirst": return .native(Array(array.dropFirst(count ?? 1)))
                default: return .native(Array(array.dropLast(count ?? 1)))
                }
            })
        case "enumerated":
            return .hostFunction(HostFunction(name: name) { _, _ in
                let tuples = array.enumerated().map { index, element in
                    RuntimeValue.native(TupleValue(labels: ["offset", "element"], values: [.native(index), element]))
                }
                return .native(tuples)
            })
        case "min", "max":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                guard !array.isEmpty else { return .none() }
                // `max(by: { $0.downloads < $1.downloads })` — the closure is
                // an areInIncreasingOrder predicate for BOTH min and max.
                if let closure = args.closure(labeled: "by") ?? args.firstUnlabeledClosure {
                    var best = array[0]
                    for element in array.dropFirst() {
                        let replace: Bool = name == "max"
                            ? try ctx.callClosure(closure, arguments: [best, element]).boolValue == true
                            : try ctx.callClosure(closure, arguments: [element, best]).boolValue == true
                        if replace { best = element }
                    }
                    return .some(best)
                }
                var best = array[0]
                for element in array.dropFirst() {
                    let better = try Builtins.binary(name == "min" ? "<" : ">", element, best)
                    if better.boolValue == true { best = element }
                }
                return .some(best)
            })
        case "randomElement":
            return .hostFunction(HostFunction(name: name) { _, _ in
                .optional(array.randomElement())
            })
        default:
            return nil
        }
    }

    /// One map/flatMap element step: a closure invokes; a key path
    /// (`.flatMap(\\.windows)`) walks its components.
    private static func mapStep(
        _ args: CallArguments, _ name: String, _ element: RuntimeValue,
        _ elementTypeName: String?,
        _ interpreter: Interpreter?, _ ctx: EvalContext
    ) throws -> RuntimeValue {
        if let closure = (args.closure(labeled: "transform") ?? args.firstUnlabeledClosure
                            ?? args.positional(0)?.closureValue) {
            if element.isNil, closure.skipsBodyForNilFirstArgument {
                interpreter?.recordPreparedOptionalChainNilSkip()
                return .none()
            }
            return try ctx.callClosure(closure, arguments: [element])
        }
        if case .host(let pathAny)? = args.positional(0), let path = pathAny as? KeyPathStub,
           let interpreter {
            return try interpreter.applyKeyPath(
                path, to: element, rootTypeName: elementTypeName)
        }
        // Unapplied function references: `.flatMap(URL.init(string:))`.
        if case .hostFunction(let fn)? = args.positional(0) {
            return try fn.invoke(CallArguments(arguments: [.init(label: nil, value: element)]), ctx)
        }
        // Init references: `.map(LocationZoneItem.init)` constructs per
        // element.
        if case .type(let symbol)? = args.positional(0), let interpreter {
            return try interpreter.instantiate(
                symbol,
                with: CallArguments(arguments: [.init(label: nil, value: element)]),
                node: nil)
        }
        throw RuntimeError(message: "\(name) needs a closure or key path")
    }

    /// Walk a key path's components off a value: instance properties,
    /// native members, host members; unknown hops become chains (absorb).
    func applyKeyPath(
        _ path: KeyPathStub,
        to start: RuntimeValue,
        rootTypeName: String? = nil
    ) throws -> RuntimeValue {
        var current = start
        var isRoot = true
        for component in path.components where component != "self" {
            if current.isNil { return .none() }
            if isRoot,
               let rootTypeName = RuntimeDeclaredType.nominalTypeName(
                   rootTypeName),
               let value = try hostExtensionMember(
                   component,
                   candidates: [rootTypeName],
                   selfValue: current) {
                current = value
                isRoot = false
                continue
            }
            switch current {
            case .instance(let instance):
                guard let value = try instanceMember(component, on: instance) else {
                    throw RuntimeError(message: "'\(instance.symbol.name)' has no member '\(component)'")
                }
                current = value
            case .tuple(let tuple):
                if let element = tuple.value(for: component) {
                    current = element
                } else {
                    current = .native(ChainedImplicitCall(
                        base: current, member: component, arguments: CallArguments()))
                }
            case .int, .double, .bool, .string, .array, .dictionary, .range:
                if let value = try nativeMember(component, on: current) {
                    current = value
                } else {
                    current = .native(ChainedImplicitCall(
                        base: current, member: component, arguments: CallArguments()))
                }
            case .host(let any):
                // Labeled tuples read their elements (`\.key` over the
                // dictionary pair shape).
                if let tuple = any as? TupleValue, let element = tuple.value(for: component) {
                    current = element
                } else if let value = try nativeMember(component, on: current)
                    ?? readHostMember(component, on: any) {
                    current = value
                } else {
                    current = .native(ChainedImplicitCall(
                        base: current, member: component, arguments: CallArguments()))
                }
            default:
                current = .native(ChainedImplicitCall(
                    base: current, member: component, arguments: CallArguments()))
            }
            isRoot = false
        }
        return current
    }

    private func stringMember(_ name: String, _ string: String) -> RuntimeValue? {
        if let generated = GeneratedCollectionDefaultSurface
            .nativeIndexMotionMember(
                named: name, receiver: .native(string)) {
            return .hostFunction(generated)
        }
        if let generated = GeneratedCollectionDefaultSurface
            .nativeIndexSearchMember(
                named: name, receiver: .native(string)) {
            return .hostFunction(generated)
        }
        if let generated = GeneratedCollectionDefaultSurface
            .nativeWritableStringCollectionView(
                named: name, on: string) {
            return generated
        }
        switch name {
        case "count": return .native(string.count)
        case "isEmpty": return .native(string.isEmpty)
        case "localizedDescription": return .native(string) // caught host errors are strings
        case "enumerated":
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(string.enumerated().map { offset, character in
                    RuntimeValue.native(TupleValue(
                        labels: ["offset", "element"],
                        values: [.native(offset), .native(Swift.String(character))]
                    ))
                })
            })
        case "forEach":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                guard let closure = args.firstUnlabeledClosure ?? args.positional(0)?.closureValue else {
                    throw RuntimeError(message: "forEach needs a closure")
                }
                for character in string {
                    _ = try ctx.callClosure(closure, arguments: [.native(Swift.String(character))])
                }
                return .void
            })
        case "components":
            return .hostFunction(HostFunction(name: name) { args, _ in
                let separator = (args.labeled("separatedBy") ?? args.positional(0))?.stringValue ?? " "
                return .native(string.components(separatedBy: separator).map { RuntimeValue.native($0) })
            })
        case "addingPercentEncoding":
            return .hostFunction(HostFunction(name: name) { args, _ in
                var allowed = CharacterSet.urlQueryAllowed
                if case .implicitMember(let setName)? = args.labeled("withAllowedCharacters") {
                    switch setName {
                    case "urlQueryAllowed": allowed = .urlQueryAllowed
                    case "urlHostAllowed": allowed = .urlHostAllowed
                    case "urlPathAllowed": allowed = .urlPathAllowed
                    case "urlUserAllowed": allowed = .urlUserAllowed
                    case "urlPasswordAllowed": allowed = .urlPasswordAllowed
                    case "urlFragmentAllowed": allowed = .urlFragmentAllowed
                    case "alphanumerics": allowed = .alphanumerics
                    case "letters": allowed = .letters
                    case "decimalDigits": allowed = .decimalDigits
                    case "whitespaces": allowed = .whitespaces
                    default: break
                    }
                }
                return .native(string.addingPercentEncoding(
                    withAllowedCharacters: allowed))
            })
        case "removingPercentEncoding":
            return .native(string.removingPercentEncoding)
        case "flatMap":
            // On a string value this is Optional.flatMap in practice
            // (`displayName.flatMap { … }` guards non-nil text): the
            // closure receives the whole string; nil short-circuits
            // upstream via nil-member propagation.
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                if let closure = args.closure(labeled: "transform") ?? args.firstUnlabeledClosure
                    ?? args.positional(0)?.closureValue {
                    return try ctx.callClosure(closure, arguments: [.native(string)])
                }
                if case .host(let pathAny)? = args.positional(0), let path = pathAny as? KeyPathStub,
                   let self {
                    return try self.applyKeyPath(path, to: .native(string))
                }
                if case .hostFunction(let fn)? = args.positional(0) {
                    return try fn.invoke(
                        CallArguments(arguments: [.init(label: nil, value: .native(string))]), ctx)
                }
                throw RuntimeError(message: "flatMap needs a closure or key path")
            })
        case "reduce", "allSatisfy", "sorted":
            // Collection HOFs delegate to the character array (single-char
            // strings) — `word.reduce(0) { $0 + points[$1] }`. min/max stay
            // out: inside String-extension bodies they'd shadow the GLOBAL
            // two-argument forms via implicit self.
            return try? arrayMember(name, string.map { .native(String($0)) })
        case "replacing":
            // The modern replacing(_:with:) — same semantics as
            // replacingOccurrences(of:with:).
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let target = args.positional(0)?.stringValue,
                      let replacement = (args.labeled("with") ?? args.positional(1))?.stringValue else {
                    throw RuntimeError(message: "replacing(_:with:) needs strings")
                }
                return .native(string.replacingOccurrences(of: target, with: replacement))
            })
        case "withCString", "withUnsafeBytes", "withUnsafeBufferPointer",
             "withUnsafeMutableBytes", "withContiguousStorageIfAvailable":
            // Pointer-based C interop: the closure needs a raw pointer we
            // can't provide — the result is unknowable (absorbs downstream).
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(ChainedImplicitCall(
                    base: .implicitMember(name), member: "result", arguments: CallArguments()))
            })
        case "utf8", "utf16":
            // Byte/code-unit views as Int arrays: .count and iteration work.
            if name == "utf8" {
                return .native(Array(string.utf8).map { RuntimeValue.native(Int($0)) })
            }
            return .native(Array(string.utf16).map { RuntimeValue.native(Int($0)) })
        case "value" where string.unicodeScalars.count == 1:
            // Unicode.Scalar.value in the single-char-string model.
            return .native(Int(string.unicodeScalars.first!.value))
        case "asciiValue" where string.count == 1:
            return .native(string.first!.asciiValue.map(Int.init))
        case "isNumber" where string.count == 1:
            return .native(string.first!.isNumber)
        case "isLetter" where string.count == 1:
            return .native(string.first!.isLetter)
        case "isWhitespace" where string.count == 1:
            return .native(string.first!.isWhitespace)
        case "appending":
            do {
                return .hostFunction(try HostFunction(
                    signature: Self.stringAppendingSignature
                ) { args, _ in
                    .native(string + args.positional(0)!.stringValue!)
                })
            } catch {
                preconditionFailure(
                    "invalid String.appending host gateway: \(error)")
            }
        case "elementsEqual":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(args.positional(0)?.stringValue == string)
            })
        case "description", "localizedDescription":
            return .native(string)
        case "debugDescription":
            // CustomDebugStringConvertible: a String reflects to its quoted,
            // escaped literal form (`"a\'b"`), matching `String(reflecting:)`.
            return .native(String(reflecting: string))
        case "localized", "localizedCapitalized", "localizedLowercase", "localizedUppercase":
            // Localization without tables: the key localizes to itself
            // (call form tolerated — Localize_Swift's `.localized()`).
            if name == "localizedCapitalized" { return .native(string.localizedCapitalized) }
            if name == "localizedLowercase" { return .native(string.localizedLowercase) }
            if name == "localizedUppercase" { return .native(string.localizedUppercase) }
            return .hostFunction(HostFunction(name: name) { _, _ in .native(string) })
        case "startIndex": return .native(string.startIndex)
        case "endIndex": return .native(string.endIndex)
        case "range":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let target = (args.labeled("of") ?? args.positional(0))?.stringValue else {
                    throw RuntimeError(message: "range(of:) needs a string")
                }
                var options: String.CompareOptions = []
                if let optionValue = args.labeled("options") {
                    func fold(_ name: String) {
                        switch name {
                        case "backwards": options.insert(.backwards)
                        case "caseInsensitive": options.insert(.caseInsensitive)
                        case "anchored": options.insert(.anchored)
                        case "regularExpression": options.insert(.regularExpression)
                        default: break
                        }
                    }
                    if case .implicitMember(let name) = optionValue { fold(name) }
                    if let array = optionValue.arrayValue {
                        for element in array {
                            if case .implicitMember(let name) = element { fold(name) }
                        }
                    }
                }
                return .native(string.range(of: target, options: options))
            })
        case "data":
            // `str.data(using: .utf8)` — real bytes (encodings beyond utf8
            // fall back to utf8, the corpus's only ask).
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(string.data(using: .utf8))
            })
        case "distance":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard case .host(let fromAny)? = args.labeled("from"), let from = fromAny as? String.Index,
                      case .host(let toAny)? = args.labeled("to"), let to = toAny as? String.Index else {
                    throw RuntimeError(message: "distance(from:to:) needs String.Index bounds")
                }
                return .native(string.distance(from: from, to: to))
            })
        case "first":
            return .optional(
                string.first.map { .native(String($0)) },
                wrappedTypeName: "Character")
        case "last":
            return .optional(
                string.last.map { .native(String($0)) },
                wrappedTypeName: "Character")
        case "uppercased":
            return .hostFunction(HostFunction(name: name) { _, _ in .native(string.uppercased()) })
        case "lowercased":
            return .hostFunction(HostFunction(name: name) { _, _ in .native(string.lowercased()) })
        case "capitalized": return .native(string.capitalized)
        case "hasPrefix":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(string.hasPrefix(args.positional(0)?.stringValue ?? ""))
            })
        case "hasSuffix":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(string.hasSuffix(args.positional(0)?.stringValue ?? ""))
            })
        case "contains":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(string.contains(args.positional(0)?.stringValue ?? ""))
            })
        case "split":
            return .hostFunction(HostFunction(name: name) { args, _ in
                let separator = args.labeled("separator")?.stringValue ?? " "
                let parts = string.components(separatedBy: separator).filter { !$0.isEmpty }
                return .native(parts.map { RuntimeValue.native($0) })
            })
        case "replacingOccurrences":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let of = args.labeled("of")?.stringValue, let with = args.labeled("with")?.stringValue else {
                    throw RuntimeError(message: "replacingOccurrences needs of: and with:")
                }
                return .native(string.replacingOccurrences(of: of, with: with))
            })
        case "trimmingCharacters":
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(string.trimmingCharacters(in: .whitespacesAndNewlines))
            })
        case "dropFirst":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(String(string.dropFirst(args.positional(0)?.intValue ?? 1)))
            })
        case "dropLast":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(String(string.dropLast(args.positional(0)?.intValue ?? 1)))
            })
        case "prefix":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(String(string.prefix(args.positional(0)?.intValue ?? string.count)))
            })
        case "suffix":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(String(string.suffix(args.positional(0)?.intValue ?? string.count)))
            })
        default:
            return nil
        }
    }

    private static func dateStyle(_ value: RuntimeValue?) -> Date.FormatStyle.DateStyle {
        guard case .implicitMember(let name)? = value else { return .omitted }
        switch name {
        case "numeric": return .numeric
        case "abbreviated": return .abbreviated
        case "long": return .long
        case "complete": return .complete
        default: return .omitted
        }
    }

    private static func timeStyle(_ value: RuntimeValue?) -> Date.FormatStyle.TimeStyle {
        guard case .implicitMember(let name)? = value else { return .omitted }
        switch name {
        case "shortened": return .shortened
        case "standard": return .standard
        case "complete": return .complete
        default: return .omitted
        }
    }

    private static func requiredClosure(_ args: CallArguments, _ name: String) throws -> ClosureValue {
        guard let closure = args.firstUnlabeledClosure ?? args.closure(labeled: "by") else {
            throw RuntimeError(message: "\(name) needs a closure argument")
        }
        return closure
    }

    /// Closures OR function values: operator refs (`reduce(0, +)`) and
    /// function refs arrive as hostFunctions, not closures.
    static func requiredCallable(
        _ args: CallArguments, _ name: String
    ) throws -> (EvalContext, [RuntimeValue]) throws -> RuntimeValue {
        if let closure = args.firstUnlabeledClosure ?? args.closure(labeled: "by") {
            return { ctx, xs in try ctx.callClosure(closure, arguments: xs) }
        }
        for argument in args.arguments {
            if case .hostFunction(let fn) = argument.value {
                return { ctx, xs in
                    try fn.invoke(CallArguments(arguments: xs.map { .init(label: nil, value: $0) }), ctx)
                }
            }
        }
        throw RuntimeError(message: "\(name) needs a closure argument")
    }
}
