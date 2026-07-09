import Foundation
import SwiftSyntax

/// Members on native values: arrays, strings, ranges, dictionaries, doubles.
/// This is the hand-written slice of the standard library that real SwiftUI
/// sample code leans on. Methods come back as bound `HostFunction`s so
/// `names.map { … }` works like any other call; closure-taking methods call
/// back through the `EvalContext`.
extension Interpreter {
    /// Returns nil when the name is unknown, so the caller can try other routes
    /// (e.g. view modifiers) before erroring.
    func nativeMember(_ name: String, on any: Any) throws -> RuntimeValue? {
        if let array = any as? [RuntimeValue] {
            return try arrayMember(name, array)
        }
        if let range = any as? Range<Int> {
            switch name {
            case "lowerBound": return .native(range.lowerBound)
            case "upperBound": return .native(range.upperBound)
            case "contains":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let v = args.positional(0)?.intValue else { return .native(false) }
                    return .native(range.contains(v))
                })
            default:
                // Everything else (count, map, …) behaves like the materialized array.
                return try arrayMember(name, range.map { .native($0) })
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
            case "keys": return .native(dict.keys)
            case "values": return .native(dict.values)
            default: return nil
            }
        }
        if let int = any as? Int, name == "truncatingRemainder" || name == "remainder"
            || name == "rounded" || name == "isZero" {
            // Interpreted math sometimes lands on Int where the source had a
            // floating value (bridge numbers are Doubles) — promote.
            return try nativeMember(name, on: Double(int))
        }
        if let double = any as? Double {
            switch name {
            case "rounded":
                return .hostFunction(HostFunction(name: name) { _, _ in .native(double.rounded()) })
            case "isZero": return .native(double.isZero)
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

    private func arrayMember(_ name: String, _ array: [RuntimeValue]) throws -> RuntimeValue? {
        switch name {
        case "count": return .native(array.count)
        case "isEmpty": return .native(array.isEmpty)
        case "first": return array.first ?? .nilValue
        case "last": return array.last ?? .nilValue
        case "indices": return .native(0..<array.count)
        case "startIndex": return .native(0)
        case "endIndex": return .native(array.count)
        case "subtracting", "union", "intersection", "symmetricDifference":
            // Set algebra on the array-backed model (Sets flatten to arrays;
            // membership by areEqual since RuntimeValue isn't Hashable).
            return .hostFunction(HostFunction(name: name) { args, _ in
                let other = args.positional(0)?.arrayValue ?? []
                let contains: ([RuntimeValue], RuntimeValue) -> Bool = { xs, v in
                    xs.contains { (try? Builtins.areEqual($0, v)) == true }
                }
                switch name {
                case "subtracting":
                    return .native(array.filter { !contains(other, $0) })
                case "union":
                    var out = array
                    for v in other where !contains(out, v) { out.append(v) }
                    return .native(out)
                case "intersection":
                    return .native(array.filter { contains(other, $0) })
                default:
                    let left = array.filter { !contains(other, $0) }
                    let right = other.filter { !contains(array, $0) }
                    return .native(left + right)
                }
            })
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

        case "flatMap":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                var out: [RuntimeValue] = []
                for element in array {
                    let mapped = try Self.mapStep(args, name, element, self, ctx)
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
                    let mapped = try Self.mapStep(args, name, element, self, ctx)
                    if name == "compactMap" && mapped.isNil { continue }
                    out.append(mapped)
                }
                return .native(out)
            })
        case "filter":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                var out: [RuntimeValue] = []
                for element in array
                where try Self.mapStep(args, name, element, self, ctx).boolValue == true {
                    out.append(element)
                }
                return .native(out)
            })
        case "allSatisfy":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                for element in array
                where try Self.mapStep(args, name, element, self, ctx).boolValue != true {
                    return .native(false)
                }
                return .native(true)
            })
        case "allSatisfy":
            return .hostFunction(HostFunction(name: name) { [weak self] args, ctx in
                for element in array
                where try Self.mapStep(args, name, element, self, ctx).boolValue != true {
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
                // `reduce(into: [:]) { acc, el in … }` — the accumulator is
                // reference-backed (DictValue) so mutations stick.
                if let into = args.labeled("into") {
                    let closure = try Self.requiredClosure(args, name)
                    for element in array {
                        _ = try ctx.callClosure(closure, arguments: [into, element])
                    }
                    return into
                }
                guard let initial = args.positional(0) else {
                    throw RuntimeError(message: "reduce needs an initial value")
                }
                let call = try Self.requiredCallable(args, name)
                var accumulator = initial
                for element in array {
                    accumulator = try call(ctx, [accumulator, element])
                }
                return accumulator
            })
        case "sorted":
            return .hostFunction(HostFunction(name: name) { args, ctx in
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
                    do { return try Builtins.binary("<", a, b).boolValue == true }
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
        case "firstIndex":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                if let closure = args.closure(labeled: "where") ?? args.firstUnlabeledClosure {
                    for (index, element) in array.enumerated()
                    where try ctx.callClosure(closure, arguments: [element]).boolValue == true {
                        return .native(index)
                    }
                    return .nilValue
                }
                guard let target = args.labeled("of") else {
                    throw RuntimeError(message: "firstIndex needs of: or where:")
                }
                for (index, element) in array.enumerated() where try Builtins.areEqual(element, target) {
                    return .native(index)
                }
                return .nilValue
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
            return .hostFunction(HostFunction(name: name) { _, _ in .native(array.shuffled()) })
        case "prefix":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(Array(array.prefix(args.positional(0)?.intValue ?? array.count)))
            })
        case "suffix":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(Array(array.suffix(args.positional(0)?.intValue ?? array.count)))
            })
        case "dropFirst":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(Array(array.dropFirst(args.positional(0)?.intValue ?? 1)))
            })
        case "dropLast":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(Array(array.dropLast(args.positional(0)?.intValue ?? 1)))
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
                guard !array.isEmpty else { return .nilValue }
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
                    return best
                }
                var best = array[0]
                for element in array.dropFirst() {
                    let better = try Builtins.binary(name == "min" ? "<" : ">", element, best)
                    if better.boolValue == true { best = element }
                }
                return best
            })
        case "randomElement":
            return .hostFunction(HostFunction(name: name) { _, _ in array.randomElement() ?? .nilValue })
        default:
            return nil
        }
    }

    /// One map/flatMap element step: a closure invokes; a key path
    /// (`.flatMap(\\.windows)`) walks its components.
    private static func mapStep(
        _ args: CallArguments, _ name: String, _ element: RuntimeValue,
        _ interpreter: Interpreter?, _ ctx: EvalContext
    ) throws -> RuntimeValue {
        if let closure = (args.closure(labeled: "transform") ?? args.firstUnlabeledClosure
                            ?? args.positional(0)?.closureValue) {
            return try ctx.callClosure(closure, arguments: [element])
        }
        if case .host(let pathAny)? = args.positional(0), let path = pathAny as? KeyPathStub,
           let interpreter {
            return try interpreter.applyKeyPath(path, to: element)
        }
        // Unapplied function references: `.flatMap(URL.init(string:))`.
        if case .hostFunction(let fn)? = args.positional(0) {
            return try fn.invoke(CallArguments(arguments: [.init(label: nil, value: element)]), ctx)
        }
        throw RuntimeError(message: "\(name) needs a closure or key path")
    }

    /// Walk a key path's components off a value: instance properties,
    /// native members, host members; unknown hops become chains (absorb).
    func applyKeyPath(_ path: KeyPathStub, to start: RuntimeValue) throws -> RuntimeValue {
        var current = start
        for component in path.components where component != "self" {
            if current.isNil { return .nilValue }
            switch current {
            case .instance(let instance):
                guard let value = try instanceMember(component, on: instance) else {
                    throw RuntimeError(message: "'\(instance.symbol.name)' has no member '\(component)'")
                }
                current = value
            case .host(let any):
                if let value = try nativeMember(component, on: any)
                    ?? registry?.hostMember(component, on: any) {
                    current = value
                } else {
                    current = .native(ChainedImplicitCall(
                        base: current, member: component, arguments: CallArguments()))
                }
            default:
                current = .native(ChainedImplicitCall(
                    base: current, member: component, arguments: CallArguments()))
            }
        }
        return current
    }

    private func stringMember(_ name: String, _ string: String) -> RuntimeValue? {
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
                return string.addingPercentEncoding(withAllowedCharacters: allowed)
                    .map { RuntimeValue.native($0) } ?? .nilValue
            })
        case "removingPercentEncoding":
            return string.removingPercentEncoding.map { RuntimeValue.native($0) } ?? .nilValue
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
            return string.first!.asciiValue.map { RuntimeValue.native(Int($0)) } ?? .nilValue
        case "isNumber" where string.count == 1:
            return .native(string.first!.isNumber)
        case "isLetter" where string.count == 1:
            return .native(string.first!.isLetter)
        case "isWhitespace" where string.count == 1:
            return .native(string.first!.isWhitespace)
        case "elementsEqual":
            return .hostFunction(HostFunction(name: name) { args, _ in
                .native(args.positional(0)?.stringValue == string)
            })
        case "unicodeScalars":
            // Scalars as single-char strings (our character model): count,
            // iteration, and allSatisfy work through array machinery.
            return .native(string.unicodeScalars.map { RuntimeValue.native(String($0)) })
        case "description", "debugDescription", "localizedDescription":
            return .native(string)
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
                guard let found = string.range(of: target, options: options) else { return .nilValue }
                return .native(found)
            })
        case "data":
            // `str.data(using: .utf8)` — real bytes (encodings beyond utf8
            // fall back to utf8, the corpus's only ask).
            return .hostFunction(HostFunction(name: name) { _, _ in
                string.data(using: .utf8).map { RuntimeValue.native($0) } ?? .nilValue
            })
        case "index":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard case .host(let any)? = args.positional(0),
                      let base = any as? String.Index else {
                    throw RuntimeError(message: "index(_:offsetBy:) needs a String.Index")
                }
                let offset = (args.labeled("offsetBy") ?? args.positional(1))?.intValue ?? 0
                let limit = offset >= 0 ? string.endIndex : string.startIndex
                guard let moved = string.index(base, offsetBy: offset, limitedBy: limit) else {
                    throw RuntimeError(message: "String index offset out of bounds")
                }
                return .native(moved)
            })
        case "distance":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard case .host(let fromAny)? = args.labeled("from"), let from = fromAny as? String.Index,
                      case .host(let toAny)? = args.labeled("to"), let to = toAny as? String.Index else {
                    throw RuntimeError(message: "distance(from:to:) needs String.Index bounds")
                }
                return .native(string.distance(from: from, to: to))
            })
        case "first": return string.first.map { .native(String($0)) } ?? .nilValue
        case "last": return string.last.map { .native(String($0)) } ?? .nilValue
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
