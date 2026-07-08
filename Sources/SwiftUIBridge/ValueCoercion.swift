import SwiftUI
import SwiftInterpreter

/// Resolves `.implicitMember` values (`.red`, `.title`, `.leading`) against
/// the SwiftUI type a gateway parameter expects — the "expected type context"
/// trick reduced to lookup tables, dodging real type inference.
enum Coerce {
    static func cgFloat(_ value: RuntimeValue) throws -> CGFloat {
        if let d = value.doubleValue { return CGFloat(d) }
        if case .implicitMember("infinity") = value { return .infinity }
        throw RuntimeError(message: "expected a number, got \(value.stringified)")
    }

    static func color(_ value: RuntimeValue) throws -> Color {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected a color like .blue, got \(value.stringified)")
        }
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
        default: throw RuntimeError(message: "unknown color '.\(name)'")
        }
    }

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
}
