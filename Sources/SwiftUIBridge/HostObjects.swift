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
    case "State":
        // `self._count = State(initialValue: 5)` — the storage IS the value.
        return HostFunction(name: name) { args, _ in
            args.labeled("initialValue") ?? args.labeled("wrappedValue") ?? args.positional(0) ?? .void
        }
    case "CGSize":
        return HostFunction(name: name) { args, _ in
            .native(CGSize(
                width: try Coerce.cgFloat(args.labeled("width") ?? .native(0)),
                height: try Coerce.cgFloat(args.labeled("height") ?? .native(0))
            ))
        }
    case "CGPoint":
        return HostFunction(name: name) { args, _ in
            .native(CGPoint(
                x: try Coerce.cgFloat(args.labeled("x") ?? .native(0)),
                y: try Coerce.cgFloat(args.labeled("y") ?? .native(0))
            ))
        }
    default:
        return nil
    }
}

/// `Calendar.current` — backed by the real Foundation calendar.
struct CalendarBox {
    let calendar = Calendar.current
}

private func dateArg(_ value: RuntimeValue?) -> Date? {
    if case .native(let any)? = value, let date = any as? Date { return date }
    if case .implicitMember("now")? = value { return Date() }
    return nil
}

private func intArg(_ value: RuntimeValue?) -> Int? {
    if let i = value?.intValue { return i }
    // `.random(in: 1...100)` arriving without type context.
    if case .native(let any)? = value, let call = any as? ImplicitMemberCall, call.name == "random",
       let range = (call.arguments.labeled("in") ?? call.arguments.positional(0))?.rangeValue {
        return Int.random(in: range)
    }
    return nil
}

private func calendarComponent(_ value: RuntimeValue?) -> Calendar.Component? {
    guard case .implicitMember(let name)? = value else { return nil }
    switch name {
    case "day": return .day
    case "month": return .month
    case "year": return .year
    case "hour": return .hour
    case "minute": return .minute
    case "second": return .second
    case "weekday": return .weekday
    default: return nil
    }
}

/// Readable members on host objects (extends bridgeHostMember's coverage).
func hostObjectMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let marker = value as? HostTypeMarker, marker.name == "Date", name == "now" {
        return .native(Date())
    }
    if let marker = value as? HostTypeMarker, marker.name == "Calendar", name == "current" {
        return .native(CalendarBox())
    }
    if let box = value as? CalendarBox {
        switch name {
        case "date":
            return .hostFunction(HostFunction(name: "date") { args, _ in
                guard let component = calendarComponent(args.labeled("byAdding")),
                      let amount = intArg(args.labeled("value")),
                      let to = dateArg(args.labeled("to")) else {
                    throw RuntimeError(message: "date(byAdding:value:to:) needs a component, value, and Date")
                }
                return box.calendar.date(byAdding: component, value: amount, to: to)
                    .map { RuntimeValue.native($0) } ?? .nilValue
            })
        case "startOfDay":
            return .hostFunction(HostFunction(name: "startOfDay") { args, _ in
                guard let date = dateArg(args.labeled("for")) else {
                    throw RuntimeError(message: "startOfDay(for:) needs a Date")
                }
                return .native(box.calendar.startOfDay(for: date))
            })
        case "component":
            return .hostFunction(HostFunction(name: "component") { args, _ in
                guard let component = calendarComponent(args.positional(0)),
                      let date = dateArg(args.labeled("from")) else {
                    throw RuntimeError(message: "component(_:from:) needs a component and Date")
                }
                return .native(box.calendar.component(component, from: date))
            })
        default:
            return nil
        }
    }
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
