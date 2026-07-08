import SwiftUI
import SwiftInterpreter

/// Resolves `.implicitMember` values (`.red`, `.title`, `.leading`) against
/// the SwiftUI type a gateway parameter expects — the "expected type context"
/// trick reduced to lookup tables, dodging real type inference.
enum Coerce {
    // MARK: - Bindings

    static func bindingBox(_ value: RuntimeValue) throws -> Box {
        if case .native(let any) = value, let stub = any as? BindingStub { return stub.box }
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
        throw RuntimeError(message: "expected a number, got \(value.stringified)")
    }

    static func double(_ value: RuntimeValue) throws -> Double {
        guard let d = value.doubleValue else {
            throw RuntimeError(message: "expected a number, got \(value.stringified)")
        }
        return d
    }

    // MARK: - Colors & shape styles

    static func color(_ value: RuntimeValue) throws -> Color {
        if case .native(let any) = value, let color = any as? Color { return color }
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

    /// The wide funnel for style positions: colors, hierarchical styles,
    /// materials, gradients, and `.color.opacity(x)` / `.color.gradient` chains.
    static func shapeStyle(_ value: RuntimeValue) throws -> AnyShapeStyle {
        if case .native(let any) = value {
            if let color = any as? Color { return AnyShapeStyle(color) }
            if let gradient = any as? LinearGradient { return AnyShapeStyle(gradient) }
            if let gradient = any as? RadialGradient { return AnyShapeStyle(gradient) }
            if let gradient = any as? AngularGradient { return AnyShapeStyle(gradient) }
            if let chained = any as? ChainedImplicitCall {
                guard let base = colorNamed(chained.baseName) else {
                    throw RuntimeError(message: "unknown color '.\(chained.baseName)'")
                }
                switch chained.member {
                case "opacity":
                    let amount = try double(chained.arguments.positional(0) ?? .native(1.0))
                    return AnyShapeStyle(base.opacity(amount))
                case "gradient":
                    return AnyShapeStyle(base.gradient)
                default:
                    throw RuntimeError(message: "unsupported style '.\(chained.baseName).\(chained.member)'")
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
        if case .native(let any) = value, let call = any as? ImplicitMemberCall, call.name == "system" {
            let size = try cgFloat(call.arguments.labeled("size") ?? .native(13))
            if let weight = call.arguments.labeled("weight") {
                return .system(size: size, weight: try fontWeight(weight))
            }
            return .system(size: size)
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
        if case .native(let any) = value, let call = any as? ImplicitMemberCall {
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
        if case .native(let any) = value, let call = any as? ImplicitMemberCall {
            let duration = call.arguments.labeled("duration")?.doubleValue
            switch call.name {
            case "easeIn": return .easeIn(duration: duration ?? 0.35)
            case "easeOut": return .easeOut(duration: duration ?? 0.35)
            case "easeInOut": return .easeInOut(duration: duration ?? 0.35)
            case "linear": return .linear(duration: duration ?? 0.35)
            case "spring": return duration.map { .spring(duration: $0) } ?? .spring()
            case "bouncy": return .bouncy
            case "smooth": return .smooth
            default: throw RuntimeError(message: "unknown animation '.\(call.name)'")
            }
        }
        throw RuntimeError(message: "expected an animation like .easeInOut")
    }

    // MARK: - Shapes & grids

    static func shape(_ value: RuntimeValue) throws -> AnyShape {
        if case .native(let any) = value, let box = any as? ShapeBox { return box.shape }
        if case .implicitMember(let name) = value {
            switch name {
            case "circle": return AnyShape(Circle())
            case "capsule": return AnyShape(Capsule())
            case "rect": return AnyShape(Rectangle())
            default: break
            }
        }
        if case .native(let any) = value, let call = any as? ImplicitMemberCall, call.name == "rect" {
            let radius = try cgFloat(call.arguments.labeled("cornerRadius") ?? .native(0))
            return AnyShape(RoundedRectangle(cornerRadius: radius))
        }
        throw RuntimeError(message: "expected a shape like Circle() or .capsule")
    }

    static func gridItems(_ value: RuntimeValue) throws -> [GridItem] {
        guard let array = value.arrayValue else {
            throw RuntimeError(message: "expected an array of GridItem")
        }
        return try array.map { element in
            if case .native(let any) = element, let item = any as? GridItem { return item }
            throw RuntimeError(message: "expected GridItem, got \(element.stringified)")
        }
    }

    static func gridItemSize(_ value: RuntimeValue) throws -> GridItem.Size {
        if case .native(let any) = value, let call = any as? ImplicitMemberCall {
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
