import AppKit
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
    case "Binding":
        // `Binding(get:set:)` — a computed binding. The box snapshots get()
        // now (bindings are reconstructed every render pass, so the snapshot
        // refreshes per pass); writes call set(newValue).
        return HostFunction(name: name) { args, ctx in
            let get = args.closure(labeled: "get")
            let set = args.closure(labeled: "set")
            let initial = try get.map { try ctx.callClosure($0, arguments: []) } ?? RuntimeValue.void
            let box = Box(initial)
            if let set {
                box.onChange = { _ = try? ctx.callClosure(set, arguments: [box.value]) }
            }
            return .native(BindingStub(box: box))
        }
    default:
        return nil
    }
}

/// `UITabBar.appearance().isHidden = true` — iOS styling side-channels have
/// no macOS analog; the proxy accepts configuration inertly (writes ignored,
/// config calls chain).
struct AppearanceStub {}

/// `Calendar.current` — backed by the real Foundation calendar.
struct CalendarBox {
    let calendar = Calendar.current
}

/// `@Environment(\.modelContext)` — SwiftData persistence has no interpreter
/// analog; the stub behaves like a fresh in-memory store: writes accepted
/// and ignored, fetches return empty.
struct ModelContextStub {}

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

/// `UIFont.systemFont(ofSize: 16, weight: .semibold)` and friends arrive as
/// implicit-member-call markers; map them onto real NSFonts so text
/// measurement uses actual metrics. Unresolvable markers fall back to the
/// system font.
private func nsFont(from value: RuntimeValue) -> NSFont? {
    if case .native(let any) = value, let font = any as? NSFont { return font }
    guard case .native(let any) = value, let call = any as? ImplicitMemberCall else { return nil }
    let size = call.arguments.labeled("ofSize")?.doubleValue.map { CGFloat($0) }
        ?? NSFont.systemFontSize
    switch call.name {
    case "systemFont":
        var weight = NSFont.Weight.regular
        if case .implicitMember(let name)? = call.arguments.labeled("weight") {
            switch name {
            case "ultraLight": weight = .ultraLight
            case "thin": weight = .thin
            case "light": weight = .light
            case "medium": weight = .medium
            case "semibold": weight = .semibold
            case "bold": weight = .bold
            case "heavy": weight = .heavy
            case "black": weight = .black
            default: break
            }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    case "boldSystemFont":
        return NSFont.boldSystemFont(ofSize: size)
    case "italicSystemFont":
        return NSFont.systemFont(ofSize: size)
    case "monospacedSystemFont":
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    case "preferredFont":
        guard case .implicitMember(let styleName)? = call.arguments.labeled("forTextStyle") else {
            return NSFont.preferredFont(forTextStyle: .body, options: [:])
        }
        let style: NSFont.TextStyle
        switch styleName {
        case "largeTitle": style = .largeTitle
        case "title", "title1": style = .title1
        case "title2": style = .title2
        case "title3": style = .title3
        case "headline": style = .headline
        case "subheadline": style = .subheadline
        case "callout": style = .callout
        case "footnote": style = .footnote
        case "caption", "caption1": style = .caption1
        case "caption2": style = .caption2
        default: style = .body
        }
        return NSFont.preferredFont(forTextStyle: style, options: [:])
    default:
        return nil
    }
}

/// Readable members on host objects (extends bridgeHostMember's coverage).
func hostObjectMember(_ name: String, on value: Any) -> RuntimeValue? {
    // Text measurement, dispatched by the evaluator's label-aware member-call
    // hook (never by plain member access — user `size` extensions win there).
    if let string = value as? String, name == "sizeWithAttributes" {
        return .hostFunction(HostFunction(name: "size") { args, _ in
            let attributes = (args.labeled("withAttributes") ?? args.positional(0))?.dictValue
            let font = attributes?.values.lazy.compactMap(nsFont(from:)).first
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let measured = (string as NSString).size(withAttributes: [.font: font])
            return .native(CGSize(width: measured.width, height: measured.height))
        })
    }
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
    if value is ModelContextStub {
        switch name {
        case "insert", "delete", "save":
            return .hostFunction(HostFunction(name: name) { _, _ in .void })
        case "fetch":
            return .hostFunction(HostFunction(name: name) { _, _ in .native([RuntimeValue]()) })
        case "fetchCount":
            return .hostFunction(HostFunction(name: name) { _, _ in .native(0) })
        case "autosaveEnabled":
            return .native(true)
        default:
            return nil
        }
    }
    if value is HostTypeMarker, name == "appearance" {
        return .hostFunction(HostFunction(name: "appearance") { _, _ in .native(AppearanceStub()) })
    }
    if value is AppearanceStub {
        // Config calls chain (`.configureWithOpaqueBackground()` → stub).
        return .hostFunction(HostFunction(name: name) { _, _ in .native(AppearanceStub()) })
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
    if value is AppearanceStub {
        return true // appearance configuration is accepted and ignored
    }
    if value is GraphicsContextStub || value is PathDrawStub {
        return true // `context.opacity = 0.5` — draw state accepted, no surface
    }
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
