import Combine
import Foundation
import SwiftInterpreter

/// Mutable host objects interpreted code constructs and configures —
/// backed by the real Foundation types. Shared by both registries.
final class DateFormatterBox {
    let formatter = DateFormatter()
}

/// `Timer.publish(every:on:in:).autoconnect()` — backed by the real Combine
/// publisher; `.onReceive` drives interpreted closures from actual ticks.
final class TimerPublisherBox {
    let interval: Double
    lazy var publisher = Timer.publish(every: interval, on: .main, in: .common).autoconnect()

    init(interval: Double) {
        self.interval = interval
    }
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
    if let marker = value as? HostTypeMarker, marker.name == "Timer", name == "publish" {
        return .hostFunction(HostFunction(name: "publish") { args, _ in
            let interval = (args.labeled("every") ?? args.positional(0))?.doubleValue ?? 1.0
            return .native(TimerPublisherBox(interval: interval)) // on:/in: accepted, main/common assumed
        })
    }
    if let box = value as? TimerPublisherBox {
        if name == "autoconnect" {
            return .hostFunction(HostFunction(name: "autoconnect") { _, _ in .native(box) })
        }
        return nil
    }
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
