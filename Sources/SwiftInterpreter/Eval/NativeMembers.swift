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
        if let data = any as? Data {
            switch name {
            case "count": return .native(data.count)
            case "isEmpty": return .native(data.isEmpty)
            case "base64EncodedString":
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(data.base64EncodedString())
                })
            default: return nil
            }
        }
        if let url = any as? URL {
            switch name {
            case "path": return .native(url.path)
            case "absoluteString": return .native(url.absoluteString)
            case "lastPathComponent": return .native(url.lastPathComponent)
            case "pathExtension": return .native(url.pathExtension)
            case "appendingPathComponent":
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard let component = args.positional(0)?.stringValue else {
                        throw RuntimeError(message: "appendingPathComponent needs a string")
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
        if let int = any as? Int, name == "truncatingRemainder" || name == "remainder" {
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

        case "flatMap":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let closure = try Self.requiredClosure(args, name)
                var out: [RuntimeValue] = []
                for element in array {
                    let mapped = try ctx.callClosure(closure, arguments: [element])
                    if let nested = mapped.arrayValue {
                        out.append(contentsOf: nested)
                    } else if !mapped.isNil {
                        out.append(mapped)
                    }
                }
                return .native(out)
            })
        case "map", "compactMap":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let closure = try Self.requiredClosure(args, name)
                var out: [RuntimeValue] = []
                for element in array {
                    let mapped = try ctx.callClosure(closure, arguments: [element])
                    if name == "compactMap" && mapped.isNil { continue }
                    out.append(mapped)
                }
                return .native(out)
            })
        case "filter":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let closure = try Self.requiredClosure(args, name)
                var out: [RuntimeValue] = []
                for element in array where try ctx.callClosure(closure, arguments: [element]).boolValue == true {
                    out.append(element)
                }
                return .native(out)
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
                guard let initial = args.positional(0) else {
                    throw RuntimeError(message: "reduce needs an initial value")
                }
                let closure = try Self.requiredClosure(args, name)
                var accumulator = initial
                for element in array {
                    accumulator = try ctx.callClosure(closure, arguments: [accumulator, element])
                }
                return accumulator
            })
        case "sorted":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                if let closure = args.closure(labeled: "by") ?? args.unlabeledClosures.first {
                    var failure: Error?
                    let out = array.sorted { a, b in
                        if failure != nil { return false }
                        do { return try ctx.callClosure(closure, arguments: [a, b]).boolValue == true }
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
                if let closure = args.closure(labeled: "where") ?? args.unlabeledClosures.first {
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
                if let closure = args.closure(labeled: "where") ?? args.unlabeledClosures.first {
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
                if let closure = args.closure(labeled: "by") ?? args.unlabeledClosures.first {
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
                guard let closure = args.unlabeledClosures.first ?? args.positional(0)?.closureValue else {
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
        case "startIndex": return .native(string.startIndex)
        case "endIndex": return .native(string.endIndex)
        case "range":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let target = (args.labeled("of") ?? args.positional(0))?.stringValue else {
                    throw RuntimeError(message: "range(of:) needs a string")
                }
                guard let found = string.range(of: target) else { return .nilValue }
                return .native(found)
            })
        case "index":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard case .native(let any)? = args.positional(0),
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
                guard case .native(let fromAny)? = args.labeled("from"), let from = fromAny as? String.Index,
                      case .native(let toAny)? = args.labeled("to"), let to = toAny as? String.Index else {
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
        guard let closure = args.unlabeledClosures.first ?? args.closure(labeled: "by") else {
            throw RuntimeError(message: "\(name) needs a closure argument")
        }
        return closure
    }
}
