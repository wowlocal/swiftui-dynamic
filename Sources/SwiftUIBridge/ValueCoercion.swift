import SwiftUI
import SwiftInterpreter

/// Resolves `.implicitMember` values (`.red`, `.title`, `.leading`) against
/// the SwiftUI type a gateway parameter expects — the "expected type context"
/// trick reduced to lookup tables, dodging real type inference.
enum Coerce {
    /// The shared unknowable test: markers, chains, inert stubs, bound
    /// host functions — the fresh-state absorption family.
    static func isUnknowable(_ value: RuntimeValue) -> Bool {
        if let payload = value.hostPayload {
            return payload is InertCallable || payload is ChainedImplicitCall
                || payload is ImplicitMemberCall
        }
        if case .implicitMember = value { return true }
        if case .hostFunction = value { return true }
        return false
    }

    // MARK: - Bindings

    static func bindingBox(_ value: RuntimeValue) throws -> Box {
        if case .host(let any) = value, let stub = any as? BindingStub { return stub.box }
        // `.constant(x)` — a binding to a fixed value (writes go nowhere).
        if case .host(let any) = value, let call = any as? ImplicitMemberCall,
           call.name == "constant" {
            return Box(call.arguments.positional(0) ?? .void)
        }
        throw RuntimeError(message: "expected a binding like $someState, got \(value.stringified)")
    }

    static func boolBinding(_ value: RuntimeValue) throws -> Binding<Bool> {
        let box = try bindingBox(value)
        return Binding(
            get: { box.value.boolValue ?? false },
            set: { box.value = .native($0) }
        )
    }

    static func stringBinding(_ value: RuntimeValue) throws -> Binding<String> {
        let box = try bindingBox(value)
        return Binding(
            get: { box.value.stringValue ?? "" },
            set: { box.value = .native($0) }
        )
    }

    /// If the underlying state is an Int, writes round back to Int so the
    /// interpreted program keeps seeing the type it declared.
    static func doubleBinding(_ value: RuntimeValue) throws -> Binding<Double> {
        let box = try bindingBox(value)
        return Binding(
            get: { box.value.doubleValue ?? 0 },
            set: { newValue in
                if box.value.intValue != nil {
                    box.value = .native(Int(newValue.rounded()))
                } else {
                    box.value = .native(newValue)
                }
            }
        )
    }

    // MARK: - Numbers

    static func cgFloat(_ value: RuntimeValue) throws -> CGFloat {
        if let d = value.doubleValue { return CGFloat(d) }
        if case .implicitMember("infinity") = value { return .infinity }
        if let z = Builtins.absorbedNumeric(value) { return CGFloat(z) }
        throw RuntimeError(message: "expected a number, got \(value.stringified)")
    }

    static func double(_ value: RuntimeValue) throws -> Double {
        if let d = value.doubleValue { return d }
        if let z = Builtins.absorbedNumeric(value) { return z }
        throw RuntimeError(message: "expected a number, got \(value.stringified)")
    }

    // MARK: - Colors & shape styles

    static func color(_ value: RuntimeValue) throws -> Color {
        if case .host(let any) = value, let color = any as? Color { return color }
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected a color like .blue, got \(value.stringified)")
        }
        guard let color = colorNamed(name) else {
            throw RuntimeError(message: "unknown color '.\(name)'")
        }
        return color
    }

    private static func colorNamed(_ name: String) -> Color? {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "white": return .white
        case "gray": return .gray
        case "black": return .black
        case "clear": return .clear
        case "primary": return .primary
        case "secondary": return .secondary
        case "accentColor": return .accentColor
        default: return nil
        }
    }

    /// A Color when the value is color-shaped: `.black`, `Color.clear`, or
    /// `.black.opacity(x)` chains. Colors are Views, so this also powers
    /// bare colors in view position.
    static func colorLike(_ value: RuntimeValue) -> Color? {
        if case .host(let any) = value, let color = any as? Color { return color }
        if case .implicitMember(let name) = value {
            return colorNamed(name)
        }
        if case .host(let any) = value, let chained = any as? ChainedImplicitCall,
           let base = colorLike(chained.base), chained.member == "opacity",
           let amount = chained.arguments.positional(0)?.doubleValue {
            return base.opacity(amount)
        }
        return nil
    }

    /// The wide funnel for style positions: colors, hierarchical styles,
    /// materials, gradients, and `.color.opacity(x)` / `.color.gradient` chains.
    static func shapeStyle(_ value: RuntimeValue) throws -> AnyShapeStyle {
        if case .host(let any) = value {
            if let style = any as? AnyShapeStyle { return style }
            if let color = any as? Color { return AnyShapeStyle(color) }
            if let gradient = any as? LinearGradient { return AnyShapeStyle(gradient) }
            if let gradient = any as? AnyGradient { return AnyShapeStyle(gradient) }
            if let gradient = any as? RadialGradient { return AnyShapeStyle(gradient) }
            if let gradient = any as? AngularGradient { return AnyShapeStyle(gradient) }
            if let chained = any as? ChainedImplicitCall {
                guard let base = colorLike(chained.base) else {
                    throw RuntimeError(message: "unknown color before '.\(chained.member)' in style chain")
                }
                switch chained.member {
                case "opacity":
                    let amount = try double(chained.arguments.positional(0) ?? .native(1.0))
                    return AnyShapeStyle(base.opacity(amount))
                case "gradient":
                    return AnyShapeStyle(base.gradient)
                default:
                    throw RuntimeError(message: "unsupported style '.\(chained.baseName ?? "…").\(chained.member)'")
                }
            }
        }
        if case .implicitMember(let name) = value {
            if let color = colorNamed(name) { return AnyShapeStyle(color) }
            switch name {
            case "tertiary": return AnyShapeStyle(.tertiary)
            case "quaternary": return AnyShapeStyle(.quaternary)
            case "ultraThinMaterial": return AnyShapeStyle(.ultraThinMaterial)
            case "thinMaterial": return AnyShapeStyle(.thinMaterial)
            case "regularMaterial": return AnyShapeStyle(.regularMaterial)
            case "thickMaterial": return AnyShapeStyle(.thickMaterial)
            case "ultraThickMaterial": return AnyShapeStyle(.ultraThickMaterial)
            case "bar": return AnyShapeStyle(.bar)
            default: break
            }
        }
        throw RuntimeError(message: "expected a color/gradient/material, got \(value.stringified)")
    }

    // MARK: - Fonts

    static func font(_ value: RuntimeValue) throws -> Font {
        if case .implicitMember(let name) = value {
            switch name {
            case "largeTitle": return .largeTitle
            case "title": return .title
            case "title2": return .title2
            case "title3": return .title3
            case "headline": return .headline
            case "subheadline": return .subheadline
            case "body": return .body
            case "callout": return .callout
            case "footnote": return .footnote
            case "caption": return .caption
            case "caption2": return .caption2
            default: throw RuntimeError(message: "unknown font '.\(name)'")
            }
        }
        if case .host(let any) = value, let font = any as? Font {
            return font
        }
        if case .host(let any) = value, let call = any as? ImplicitMemberCall, call.name == "system" {
            let size = try cgFloat(call.arguments.labeled("size") ?? .native(13))
            let design: Font.Design = switch call.arguments.labeled("design") {
            case .implicitMember("serif"): .serif
            case .implicitMember("rounded"): .rounded
            case .implicitMember("monospaced"): .monospaced
            default: .default
            }
            if let weight = call.arguments.labeled("weight") {
                return .system(size: size, weight: try fontWeight(weight), design: design)
            }
            return .system(size: size, design: design)
        }
        // Font-returning chains — `.largeTitle.bold()`, `Font.system(size:
        // 48).weight(.black)` — apply members to the recursively-coerced base.
        if case .host(let any) = value, let chained = any as? ChainedImplicitCall {
            let base = try font(chained.base)
            switch chained.member {
            case "bold": return base.bold()
            case "italic": return base.italic()
            case "monospaced": return base.monospaced()
            case "monospacedDigit": return base.monospacedDigit()
            case "smallCaps": return base.smallCaps()
            case "weight":
                return base.weight(try fontWeight(chained.arguments.positional(0) ?? .implicitMember("regular")))
            default:
                throw RuntimeError(message: "unsupported font member '.\(chained.member)'")
            }
        }
        throw RuntimeError(message: "expected a font like .title, got \(value.stringified)")
    }

    static func fontWeight(_ value: RuntimeValue) throws -> Font.Weight {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected a font weight like .bold")
        }
        switch name {
        case "ultraLight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: throw RuntimeError(message: "unknown font weight '.\(name)'")
        }
    }

    // MARK: - Alignment & layout

    static func horizontalAlignment(_ value: RuntimeValue) throws -> HorizontalAlignment {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected an alignment like .leading")
        }
        switch name {
        case "leading": return .leading
        case "center": return .center
        case "trailing": return .trailing
        default: throw RuntimeError(message: "unknown horizontal alignment '.\(name)'")
        }
    }

    static func verticalAlignment(_ value: RuntimeValue) throws -> VerticalAlignment {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected an alignment like .top")
        }
        switch name {
        case "top": return .top
        case "center": return .center
        case "bottom": return .bottom
        case "firstTextBaseline": return .firstTextBaseline
        case "lastTextBaseline": return .lastTextBaseline
        default: throw RuntimeError(message: "unknown vertical alignment '.\(name)'")
        }
    }

    static func alignment(_ value: RuntimeValue) throws -> Alignment {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected an alignment like .center")
        }
        switch name {
        case "center": return .center
        case "leading": return .leading
        case "trailing": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: throw RuntimeError(message: "unknown alignment '.\(name)'")
        }
    }

    static func edgeSet(_ value: RuntimeValue) throws -> Edge.Set {
        // `[.top, .bottom]` / `[]` — Edge.Set is an OptionSet, and array
        // literals of edges are how damus (and SwiftUI docs) spell unions.
        if let elements = value.arrayValue {
            var union: Edge.Set = []
            for element in elements {
                union.formUnion(try edgeSet(element))
            }
            return union
        }
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected edges like .horizontal")
        }
        switch name {
        case "all": return .all
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        default: throw RuntimeError(message: "unknown edge set '.\(name)'")
        }
    }

    static func unitPoint(_ value: RuntimeValue) throws -> UnitPoint {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected a unit point like .top")
        }
        switch name {
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        case "center": return .center
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: throw RuntimeError(message: "unknown unit point '.\(name)'")
        }
    }

    static func textAlignment(_ value: RuntimeValue) throws -> TextAlignment {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected .leading/.center/.trailing")
        }
        switch name {
        case "leading": return .leading
        case "center": return .center
        case "trailing": return .trailing
        default: throw RuntimeError(message: "unknown text alignment '.\(name)'")
        }
    }

    static func contentMode(_ value: RuntimeValue) throws -> ContentMode {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected .fit or .fill")
        }
        switch name {
        case "fit": return .fit
        case "fill": return .fill
        default: throw RuntimeError(message: "unknown content mode '.\(name)'")
        }
    }

    static func calendarComponent(_ value: RuntimeValue) throws -> Calendar.Component {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected a Calendar.Component like .day")
        }
        switch name {
        case "era": return .era
        case "year": return .year
        case "month": return .month
        case "day": return .day
        case "hour": return .hour
        case "minute": return .minute
        case "second": return .second
        case "weekday": return .weekday
        case "weekdayOrdinal": return .weekdayOrdinal
        case "quarter": return .quarter
        case "weekOfMonth": return .weekOfMonth
        case "weekOfYear": return .weekOfYear
        case "yearForWeekOfYear": return .yearForWeekOfYear
        case "nanosecond": return .nanosecond
        case "calendar": return .calendar
        case "timeZone": return .timeZone
        default: throw RuntimeError(message: "unknown Calendar.Component '.\(name)'")
        }
    }

    static func imageScale(_ value: RuntimeValue) throws -> Image.Scale {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected .small/.medium/.large")
        }
        switch name {
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        default: throw RuntimeError(message: "unknown image scale '.\(name)'")
        }
    }

    // MARK: - Angles & animation

    static func angle(_ value: RuntimeValue) throws -> Angle {
        if case .host(let any) = value, let call = any as? ImplicitMemberCall {
            let amount = try double(call.arguments.positional(0) ?? .native(0.0))
            switch call.name {
            case "degrees": return .degrees(amount)
            case "radians": return .radians(amount)
            default: break
            }
        }
        if let d = value.doubleValue { return .degrees(d) }
        throw RuntimeError(message: "expected an angle like .degrees(45)")
    }

    static func animation(_ value: RuntimeValue) throws -> Animation {
        if case .implicitMember(let name) = value {
            switch name {
            case "default": return .default
            case "easeIn": return .easeIn
            case "easeOut": return .easeOut
            case "easeInOut": return .easeInOut
            case "linear": return .linear
            case "spring": return .spring
            case "bouncy": return .bouncy
            case "smooth": return .smooth
            case "snappy": return .snappy
            default: throw RuntimeError(message: "unknown animation '.\(name)'")
            }
        }
        if case .host(let any) = value, let call = any as? ImplicitMemberCall {
            let duration = call.arguments.labeled("duration")?.doubleValue
            switch call.name {
            case "easeIn": return .easeIn(duration: duration ?? 0.35)
            case "easeOut": return .easeOut(duration: duration ?? 0.35)
            case "easeInOut": return .easeInOut(duration: duration ?? 0.35)
            case "linear": return .linear(duration: duration ?? 0.35)
            case "spring", "interactiveSpring", "interpolatingSpring":
                // The response/dampingFraction family; interactiveSpring is
                // a lower-response spring, close enough via the same params.
                if let response = call.arguments.labeled("response")?.doubleValue {
                    let damping = call.arguments.labeled("dampingFraction")?.doubleValue ?? 0.825
                    let blend = call.arguments.labeled("blendDuration")?.doubleValue ?? 0
                    return .spring(response: response, dampingFraction: damping, blendDuration: blend)
                }
                if let damping = call.arguments.labeled("dampingFraction")?.doubleValue {
                    return .spring(response: call.name == "interactiveSpring" ? 0.15 : 0.5, dampingFraction: damping)
                }
                return duration.map { .spring(duration: $0) }
                    ?? (call.name == "interactiveSpring" ? .interactiveSpring() : .spring())
            case "bouncy": return .bouncy
            case "smooth": return .smooth
            case "snappy":
                if let extraBounce = call.arguments.labeled("extraBounce")?.doubleValue {
                    return .snappy(duration: duration ?? 0.5, extraBounce: extraBounce)
                }
                return .snappy(duration: duration ?? 0.5)
            default: throw RuntimeError(message: "unknown animation '.\(call.name)'")
            }
        }
        // Combinator chains fold recursively:
        // `.easeInOut(duration: 0.3).delay(0.2).repeatForever(autoreverses: false)`
        if case .host(let any) = value, let chained = any as? ChainedImplicitCall {
            let base = try animation(chained.base)
            let first = chained.arguments.positional(0)
            switch chained.member {
            case "delay":
                return base.delay(try double(first ?? .native(0.0)))
            case "speed":
                return base.speed(try double(first ?? .native(1.0)))
            case "repeatForever":
                let auto = (chained.arguments.labeled("autoreverses") ?? first)?.boolValue ?? true
                return base.repeatForever(autoreverses: auto)
            case "repeatCount":
                let auto = (chained.arguments.labeled("autoreverses") ?? chained.arguments.positional(1))?.boolValue ?? true
                return base.repeatCount(first?.intValue ?? 1, autoreverses: auto)
            default:
                throw RuntimeError(message: "unknown animation combinator '.\(chained.member)'")
            }
        }
        throw RuntimeError(message: "expected an animation like .easeInOut")
    }

    // MARK: - Shapes & grids

    static func shape(_ value: RuntimeValue) throws -> AnyShape {
        if case .host(let any) = value, let box = any as? ShapeBox { return box.shape }
        if case .implicitMember(let name) = value {
            switch name {
            case "circle": return AnyShape(Circle())
            case "capsule": return AnyShape(Capsule())
            case "rect": return AnyShape(Rectangle())
            default: break
            }
        }
        if case .host(let any) = value, let call = any as? ImplicitMemberCall, call.name == "rect" {
            let radius = try cgFloat(call.arguments.labeled("cornerRadius") ?? .native(0))
            return AnyShape(RoundedRectangle(cornerRadius: radius))
        }
        if case .host(let any) = value,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            // Unknowable shapes (external-SDK shape builders) degrade to the
            // bounding rectangle — clipping to bounds is the honest no-op.
            return AnyShape(Rectangle())
        }
        if case .hostFunction = value { return AnyShape(Rectangle()) }
        throw RuntimeError(message: "expected a shape like Circle() or .capsule")
    }

    static func gridItems(_ value: RuntimeValue) throws -> [GridItem] {
        guard let array = value.arrayValue else {
            throw RuntimeError(message: "expected an array of GridItem")
        }
        return try array.map { element in
            if case .host(let any) = element, let item = any as? GridItem { return item }
            throw RuntimeError(message: "expected GridItem, got \(element.stringified)")
        }
    }

    static func gridItemSize(_ value: RuntimeValue) throws -> GridItem.Size {
        if case .host(let any) = value, let call = any as? ImplicitMemberCall {
            switch call.name {
            case "flexible":
                return .flexible(
                    minimum: try cgFloat(call.arguments.labeled("minimum") ?? .native(10)),
                    maximum: try cgFloat(call.arguments.labeled("maximum") ?? .implicitMember("infinity"))
                )
            case "fixed":
                return .fixed(try cgFloat(call.arguments.positional(0) ?? .native(50)))
            case "adaptive":
                return .adaptive(
                    minimum: try cgFloat(call.arguments.labeled("minimum") ?? .native(50)),
                    maximum: try cgFloat(call.arguments.labeled("maximum") ?? .implicitMember("infinity"))
                )
            default: break
            }
        }
        if case .implicitMember("flexible") = value { return .flexible() }
        throw RuntimeError(message: "expected .flexible()/.fixed(n)/.adaptive(minimum:)")
    }
}
