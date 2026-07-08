import SwiftUI
import SwiftInterpreter

/// Modifier gateways: `.padding`, `.font`, `.foregroundStyle`, `.background`,
/// `.cornerRadius`, `.frame`, `.opacity`, `.bold`, … applied to `AnyView`.
extension ViewRegistry {
    func registerModifiers() {
        register("padding") { view, args, _ in
            if args.isEmpty { return AnyView(view.padding()) }
            if let first = args.positional(0), case .implicitMember = first {
                let edges = try Coerce.edgeSet(first)
                if let length = args.positional(1) {
                    return AnyView(view.padding(edges, try Coerce.cgFloat(length)))
                }
                return AnyView(view.padding(edges))
            }
            if let length = args.positional(0) {
                return AnyView(view.padding(try Coerce.cgFloat(length)))
            }
            return AnyView(view.padding())
        }

        register("font") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".font needs an argument") }
            return AnyView(view.font(try Coerce.font(value)))
        }

        register("bold") { view, _, _ in AnyView(view.bold()) }
        register("italic") { view, _, _ in AnyView(view.italic()) }

        register("fontWeight") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".fontWeight needs an argument") }
            return AnyView(view.fontWeight(try Coerce.fontWeight(value)))
        }

        let foreground: @MainActor (AnyView, CallArguments, EvalContext) throws -> AnyView = { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: "missing color argument") }
            return AnyView(view.foregroundStyle(try Coerce.color(value)))
        }
        register("foregroundStyle", foreground)
        register("foregroundColor", foreground)

        register("background") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".background needs a color") }
            return AnyView(view.background(try Coerce.color(value)))
        }

        register("cornerRadius") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".cornerRadius needs a radius") }
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: try Coerce.cgFloat(value))))
        }

        register("opacity") { view, args, _ in
            guard let value = args.positional(0), let amount = value.doubleValue else {
                throw RuntimeError(message: ".opacity needs a number")
            }
            return AnyView(view.opacity(amount))
        }

        register("frame") { view, args, _ in
            let width = try args.labeled("width").map(Coerce.cgFloat)
            let height = try args.labeled("height").map(Coerce.cgFloat)
            let maxWidth = try args.labeled("maxWidth").map(Coerce.cgFloat)
            let maxHeight = try args.labeled("maxHeight").map(Coerce.cgFloat)
            let alignment = try args.labeled("alignment").map(Coerce.alignment) ?? .center

            var result = view
            if width != nil || height != nil {
                result = AnyView(result.frame(width: width, height: height, alignment: alignment))
            }
            if maxWidth != nil || maxHeight != nil {
                result = AnyView(result.frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment))
            }
            if width == nil && height == nil && maxWidth == nil && maxHeight == nil {
                throw RuntimeError(message: ".frame needs width/height/maxWidth/maxHeight")
            }
            return result
        }
    }

    private func register(_ name: String, _ transform: @escaping @MainActor (AnyView, CallArguments, EvalContext) throws -> AnyView) {
        modifiers[name] = HostModifier(name: name) { value, args, ctx in
            .native(try transform(try Self.anyView(value), args, ctx))
        }
    }
}
