import Foundation
import SwiftInterpreter

/// Mutable host objects interpreted code constructs and configures —
/// backed by the real Foundation types. Shared by both registries.
final class DateFormatterBox {
    let formatter = DateFormatter()
}

/// Constructors for host object types, consulted by both registries before
/// their own tables.
func bridgeHostObjectConstructor(named name: String) -> HostFunction? {
    switch name {
    case "DateFormatter":
        return HostFunction(name: name) { _, _ in .native(DateFormatterBox()) }
    default:
        return nil
    }
}

/// Readable members on host objects (extends bridgeHostMember's coverage).
func hostObjectMember(_ name: String, on value: Any) -> RuntimeValue? {
    guard let box = value as? DateFormatterBox else { return nil }
    switch name {
    case "dateFormat":
        return .native(box.formatter.dateFormat ?? "")
    case "string":
        return .hostFunction(HostFunction(name: "string") { args, _ in
            guard case .native(let any)? = args.labeled("from") ?? args.positional(0),
                  let date = any as? Date else {
                throw RuntimeError(message: "string(from:) needs a Date")
            }
            return .native(box.formatter.string(from: date))
        })
    case "date":
        return .hostFunction(HostFunction(name: "date") { args, _ in
            guard let text = (args.labeled("from") ?? args.positional(0))?.stringValue else {
                throw RuntimeError(message: "date(from:) needs a String")
            }
            return box.formatter.date(from: text).map { RuntimeValue.native($0) } ?? .nilValue
        })
    default:
        return nil
    }
}

/// Writable members on host objects.
func hostObjectSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
    guard let box = value as? DateFormatterBox else { return false }
    switch name {
    case "dateFormat":
        guard let format = newValue.stringValue else { return false }
        box.formatter.dateFormat = format
        return true
    default:
        return false
    }
}
