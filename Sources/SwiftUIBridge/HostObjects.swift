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

/// `NumberFormatter` — backed by the real Foundation formatter; numberStyle
/// and fraction-digit writes configure it, string(from:) really formats.
final class NumberFormatterBox {
    let formatter = NumberFormatter()
}

/// Constructors for host object types, consulted by both registries before
/// their own tables.
func bridgeHostObjectConstructor(named name: String) -> HostFunction? {
    switch name {
    case "DateFormatter":
        return HostFunction(name: name) { _, _ in .native(DateFormatterBox()) }
    case "NumberFormatter":
        return HostFunction(name: name) { _, _ in .native(NumberFormatterBox()) }
    case "NSNumber":
        // Our numbers are already boxed RuntimeValues — pass through.
        return HostFunction(name: name) { args, _ in
            args.labeled("value") ?? args.positional(0) ?? .native(0)
        }
    case "State":
        // `self._count = State(initialValue: 5)` — the storage IS the value.
        return HostFunction(name: name) { args, _ in
            args.labeled("initialValue") ?? args.labeled("wrappedValue") ?? args.positional(0) ?? .void
        }
    case "Query", "FetchRequest", "SectionedFetchRequest", "ObservedResults":
        // `_list = Query(descriptor, animation: .snappy)` in custom inits —
        // the storage is fresh-store results: empty (same doctrine as the
        // wrapper flatten).
        return HostFunction(name: name) { _, _ in .native([RuntimeValue]()) }
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
    case "DateComponents":
        return HostFunction(name: name) { args, _ in
            var components = DateComponents()
            components.year = args.labeled("year")?.intValue
            components.month = args.labeled("month")?.intValue
            components.day = args.labeled("day")?.intValue
            components.hour = args.labeled("hour")?.intValue
            components.minute = args.labeled("minute")?.intValue
            components.second = args.labeled("second")?.intValue
            return .native(DateComponentsBox(components: components))
        }
    case "AttributedString":
        return HostFunction(name: name) { args, _ in
            .native(AttributedStringBox(AttributedString(args.positional(0)?.stringValue ?? "")))
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

/// `calendar.dateComponents([.hour, .minute], from:to:)` results and
/// `DateComponents()` builders — member reads AND writes hit real values.
final class DateComponentsBox {
    var components: DateComponents

    init(components: DateComponents) {
        self.components = components
    }
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

/// DateComponents from a box OR an `.init(month: 1, minute: -1)` marker.
private func dateComponentsArg(_ value: RuntimeValue?) -> DateComponents? {
    if case .native(let any)? = value, let box = any as? DateComponentsBox {
        return box.components
    }
    if case .native(let any)? = value, let call = any as? ImplicitMemberCall, call.name == "init" {
        var components = DateComponents()
        components.year = call.arguments.labeled("year")?.intValue
        components.month = call.arguments.labeled("month")?.intValue
        components.day = call.arguments.labeled("day")?.intValue
        components.hour = call.arguments.labeled("hour")?.intValue
        components.minute = call.arguments.labeled("minute")?.intValue
        components.second = call.arguments.labeled("second")?.intValue
        components.weekday = call.arguments.labeled("weekday")?.intValue
        return components
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
    case "weekOfMonth": return .weekOfMonth
    case "weekOfYear": return .weekOfYear
    case "quarter": return .quarter
    default: return nil
    }
}

/// `calendar.dateInterval(of:for:)` results — start/end/duration reads.
struct DateIntervalBox {
    let interval: DateInterval
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
                // `date(from: components)` — reconstitute from parts.
                if let components = dateComponentsArg(args.labeled("from")) {
                    return box.calendar.date(from: components)
                        .map { RuntimeValue.native($0) } ?? .nilValue
                }
                // `date(byAdding: .init(month: 1, minute: -1), to: d)` —
                // components as a box or an .init marker.
                if let components = dateComponentsArg(args.labeled("byAdding")),
                   let to = dateArg(args.labeled("to")) {
                    return box.calendar.date(byAdding: components, to: to)
                        .map { RuntimeValue.native($0) } ?? .nilValue
                }
                // `date(bySettingHour:minute:second:of:)`.
                if let hour = args.labeled("bySettingHour")?.intValue,
                   let of = dateArg(args.labeled("of")) {
                    return box.calendar.date(
                        bySettingHour: hour,
                        minute: args.labeled("minute")?.intValue ?? 0,
                        second: args.labeled("second")?.intValue ?? 0,
                        of: of
                    ).map { RuntimeValue.native($0) } ?? .nilValue
                }
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
        case "dateComponents":
            return .hostFunction(HostFunction(name: "dateComponents") { args, _ in
                let set = Set((args.positional(0)?.arrayValue ?? []).compactMap { calendarComponent($0) })
                guard !set.isEmpty, let from = dateArg(args.labeled("from")) else {
                    throw RuntimeError(message: "dateComponents needs components and a from: Date")
                }
                if let to = dateArg(args.labeled("to")) {
                    return .native(DateComponentsBox(components: box.calendar.dateComponents(set, from: from, to: to)))
                }
                return .native(DateComponentsBox(components: box.calendar.dateComponents(set, from: from)))
            })
        case "range":
            return .hostFunction(HostFunction(name: "range") { args, _ in
                guard let smaller = calendarComponent(args.labeled("of") ?? args.positional(0)),
                      let larger = calendarComponent(args.labeled("in")),
                      let date = dateArg(args.labeled("for")) else {
                    throw RuntimeError(message: "range(of:in:for:) needs two components and a Date")
                }
                return box.calendar.range(of: smaller, in: larger, for: date)
                    .map { RuntimeValue.native($0) } ?? .nilValue
            })
        case "monthSymbols":
            return .native(box.calendar.monthSymbols.map { RuntimeValue.native($0) })
        case "shortMonthSymbols":
            return .native(box.calendar.shortMonthSymbols.map { RuntimeValue.native($0) })
        case "weekdaySymbols":
            return .native(box.calendar.weekdaySymbols.map { RuntimeValue.native($0) })
        case "shortWeekdaySymbols":
            return .native(box.calendar.shortWeekdaySymbols.map { RuntimeValue.native($0) })
        case "isDateInToday", "isDateInTomorrow", "isDateInYesterday", "isDateInWeekend":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let date = dateArg(args.positional(0)) else {
                    throw RuntimeError(message: "\(name) needs a Date")
                }
                switch name {
                case "isDateInTomorrow": return .native(box.calendar.isDateInTomorrow(date))
                case "isDateInYesterday": return .native(box.calendar.isDateInYesterday(date))
                case "isDateInWeekend": return .native(box.calendar.isDateInWeekend(date))
                default: return .native(box.calendar.isDateInToday(date))
                }
            })
        case "dateInterval":
            return .hostFunction(HostFunction(name: "dateInterval") { args, _ in
                guard let component = calendarComponent(args.labeled("of")),
                      let date = dateArg(args.labeled("for")) else {
                    throw RuntimeError(message: "dateInterval(of:for:) needs a component and a Date")
                }
                return box.calendar.dateInterval(of: component, for: date)
                    .map { RuntimeValue.native(DateIntervalBox(interval: $0)) } ?? .nilValue
            })
        case "isDate":
            return .hostFunction(HostFunction(name: "isDate") { args, _ in
                guard let lhs = dateArg(args.positional(0)),
                      let rhs = dateArg(args.labeled("inSameDayAs")) else {
                    throw RuntimeError(message: "isDate(_:inSameDayAs:) needs two Dates")
                }
                return .native(box.calendar.isDate(lhs, inSameDayAs: rhs))
            })
        default:
            return nil
        }
    }
    if let box = value as? DateIntervalBox {
        switch name {
        case "start": return .native(box.interval.start)
        case "end": return .native(box.interval.end)
        case "duration": return .native(box.interval.duration)
        default: return nil
        }
    }
    if let box = value as? DateComponentsBox {
        switch name {
        case "hour": return box.components.hour.map { .native($0) } ?? .nilValue
        case "minute": return box.components.minute.map { .native($0) } ?? .nilValue
        case "second": return box.components.second.map { .native($0) } ?? .nilValue
        case "day": return box.components.day.map { .native($0) } ?? .nilValue
        case "month": return box.components.month.map { .native($0) } ?? .nilValue
        case "year": return box.components.year.map { .native($0) } ?? .nilValue
        case "weekday": return box.components.weekday.map { .native($0) } ?? .nilValue
        default: return nil
        }
    }
    if let stub = value as? EnvironmentValuesStub {
        return stub.values[name]
    }
    if let box = value as? AttributedStringBox {
        switch name {
        case "range":
            return .hostFunction(HostFunction(name: "range") { args, _ in
                guard let text = (args.labeled("of") ?? args.positional(0))?.stringValue,
                      let range = box.attributed.range(of: text) else { return .nilValue }
                return .native(AttributedRangeBox(range))
            })
        case "subscript":
            return .hostFunction(HostFunction(name: "subscript") { args, _ in
                guard case .native(let any)? = args.positional(0),
                      let rangeBox = any as? AttributedRangeBox else {
                    throw RuntimeError(message: "AttributedString subscripting needs a range from range(of:)")
                }
                return .native(AttributedRangeProxy(box: box, range: rangeBox.range))
            })
        default:
            return nil
        }
    }
    if let box = value as? NumberFormatterBox {
        switch name {
        case "string":
            return .hostFunction(HostFunction(name: "string") { args, _ in
                var value = args.labeled("from") ?? args.positional(0)
                // `.init(value: x)` — the NSNumber marker unwraps to x.
                if case .native(let any)? = value, let call = any as? ImplicitMemberCall,
                   call.name == "init" {
                    value = call.arguments.labeled("value") ?? call.arguments.positional(0)
                }
                guard let number = value?.doubleValue else {
                    throw RuntimeError(message: "string(from:) needs a number")
                }
                return .native(box.formatter.string(from: NSNumber(value: number)) ?? "\(number)")
            })
        case "number":
            return .hostFunction(HostFunction(name: "number") { args, _ in
                guard let text = (args.labeled("from") ?? args.positional(0))?.stringValue,
                      let parsed = box.formatter.number(from: text) else { return .nilValue }
                return .native(parsed.doubleValue)
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
            guard let date = dateArg(args.labeled("from") ?? args.positional(0)) else {
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
    if value is ImplicitMemberCall || value is ChainedImplicitCall {
        // Unresolvable host objects (`manager.delegate = self` on a marker
        // CLLocationManager) — config writes are dead machinery headlessly.
        return true
    }
    if let stub = value as? UIKitStub {
        stub.config[name] = newValue
        return true
    }
    if let box = value as? NumberFormatterBox {
        switch name {
        case "numberStyle":
            if case .implicitMember(let style) = newValue {
                switch style {
                case "decimal": box.formatter.numberStyle = .decimal
                case "currency": box.formatter.numberStyle = .currency
                case "percent": box.formatter.numberStyle = .percent
                case "ordinal": box.formatter.numberStyle = .ordinal
                default: break
                }
            }
            return true
        case "maximumFractionDigits":
            if let digits = newValue.intValue { box.formatter.maximumFractionDigits = digits }
            return true
        case "minimumFractionDigits":
            if let digits = newValue.intValue { box.formatter.minimumFractionDigits = digits }
            return true
        case "locale", "currencySymbol", "groupingSeparator", "allowsFloats":
            return true // accepted; defaults suffice headlessly
        default:
            return false
        }
    }
    if value is AppearanceStub {
        return true // appearance configuration is accepted and ignored
    }
    if value is GraphicsContextStub || value is PathDrawStub {
        return true // `context.opacity = 0.5` — draw state accepted, no surface
    }
    if let box = value as? NumberFormatterBox {
        switch name {
        case "numberStyle":
            if case .implicitMember(let style) = newValue {
                switch style {
                case "decimal": box.formatter.numberStyle = .decimal
                case "currency": box.formatter.numberStyle = .currency
                case "percent": box.formatter.numberStyle = .percent
                case "ordinal": box.formatter.numberStyle = .ordinal
                default: break
                }
            }
            return true
        case "maximumFractionDigits":
            if let digits = newValue.intValue { box.formatter.maximumFractionDigits = digits }
            return true
        case "minimumFractionDigits":
            if let digits = newValue.intValue { box.formatter.minimumFractionDigits = digits }
            return true
        case "locale", "currencySymbol", "groupingSeparator", "allowsFloats":
            return true // accepted; defaults suffice headlessly
        default:
            return false
        }
    }
    if let box = value as? DateComponentsBox {
        guard let amount = newValue.intValue ?? newValue.doubleValue.map({ Int($0) }) else { return false }
        switch name {
        case "year": box.components.year = amount
        case "month": box.components.month = amount
        case "day": box.components.day = amount
        case "hour": box.components.hour = amount
        case "minute": box.components.minute = amount
        case "second": box.components.second = amount
        case "weekday": box.components.weekday = amount
        default: return false
        }
        return true
    }
    if let box = value as? AttributedStringBox {
        switch name {
        case "foregroundColor":
            if let color = Coerce.colorLike(newValue) { box.attributed.foregroundColor = color }
            return true
        case "font":
            if let font = try? Coerce.font(newValue) { box.attributed.font = font }
            return true
        case "underlineStyle", "underlineColor", "backgroundColor", "link":
            return true
        default:
            return false
        }
    }
    if let proxy = value as? AttributedRangeProxy {
        switch name {
        case "foregroundColor":
            if let color = Coerce.colorLike(newValue) {
                proxy.box.attributed[proxy.range].foregroundColor = color
            }
            return true
        case "font":
            if let font = try? Coerce.font(newValue) {
                proxy.box.attributed[proxy.range].font = font
            }
            return true
        case "underlineStyle", "underlineColor", "backgroundColor", "link":
            return true // accepted; not yet rendered
        default:
            return false
        }
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
