import SwiftUI
import SwiftInterpreter

/// Constructor gateways: `Text`, stacks, `Button`, `Image(systemName:)`,
/// `Spacer`, `Divider`, `ForEach`. Each accepts dynamic arguments and calls
/// the real SwiftUI initializer.
extension ViewRegistry {
    func registerViews() {
        constructors["Text"] = HostFunction(name: "Text") { args, _ in
            guard let value = args.positional(0) else {
                throw RuntimeError(message: "Text needs a string argument")
            }
            return .native(AnyView(Text(value.stringValue ?? value.stringified)))
        }

        constructors["Image"] = HostFunction(name: "Image") { args, _ in
            guard let name = args.labeled("systemName")?.stringValue else {
                throw RuntimeError(message: "only Image(systemName:) is supported")
            }
            return .native(AnyView(Image(systemName: name)))
        }

        constructors["Spacer"] = HostFunction(name: "Spacer") { _, _ in
            .native(AnyView(Spacer()))
        }

        constructors["Divider"] = HostFunction(name: "Divider") { _, _ in
            .native(AnyView(Divider()))
        }

        constructors["VStack"] = HostFunction(name: "VStack") { args, ctx in
            let alignment = try args.labeled("alignment").map(Coerce.horizontalAlignment) ?? .center
            let spacing = try args.labeled("spacing").map(Coerce.cgFloat)
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(VStack(alignment: alignment, spacing: spacing) { Self.indexed(content) }))
        }

        constructors["HStack"] = HostFunction(name: "HStack") { args, ctx in
            let alignment = try args.labeled("alignment").map(Coerce.verticalAlignment) ?? .center
            let spacing = try args.labeled("spacing").map(Coerce.cgFloat)
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(HStack(alignment: alignment, spacing: spacing) { Self.indexed(content) }))
        }

        constructors["ZStack"] = HostFunction(name: "ZStack") { args, ctx in
            let alignment = try args.labeled("alignment").map(Coerce.alignment) ?? .center
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(ZStack(alignment: alignment) { Self.indexed(content) }))
        }

        constructors["Button"] = HostFunction(name: "Button") { args, ctx in
            let title = args.positional(0)?.stringValue
            let unlabeled = args.unlabeledClosures

            let actionClosure: ClosureValue?
            let labelClosure: ClosureValue?
            if let labeled = args.closure(labeled: "action") {
                actionClosure = labeled
                labelClosure = args.closure(labeled: "label") ?? unlabeled.first
            } else {
                // `Button("+") { … }` or `Button { … } label: { … }`
                actionClosure = unlabeled.first
                labelClosure = args.closure(labeled: "label") ?? (unlabeled.count > 1 ? unlabeled[1] : nil)
            }
            guard let actionClosure else {
                throw RuntimeError(message: "Button needs an action closure")
            }

            let label: AnyView
            if let labelClosure {
                let views = try ctx.callBuilderClosure(labelClosure, arguments: []).map(Self.anyView)
                label = views.count == 1 ? views[0] : AnyView(HStack { Self.indexed(views) })
            } else if let title {
                label = AnyView(Text(title))
            } else {
                throw RuntimeError(message: "Button needs a title or a label closure")
            }

            let action = { _ = try? ctx.callClosure(actionClosure, arguments: []) }
            return .native(AnyView(Button(action: action) { label }))
        }

        constructors["ForEach"] = HostFunction(name: "ForEach") { args, ctx in
            guard let data = args.positional(0) else {
                throw RuntimeError(message: "ForEach needs a range or an array")
            }
            guard let content = args.closure(labeled: "content") ?? args.unlabeledClosures.last else {
                throw RuntimeError(message: "ForEach needs a content closure")
            }
            let elements = try Self.forEachElements(data)
            var views: [AnyView] = []
            for element in elements {
                views += try ctx.callBuilderClosure(content, arguments: [element]).map(Self.anyView)
            }
            return .native(AnyView(Self.indexed(views)))
        }
    }

    static func forEachElements(_ data: RuntimeValue) throws -> [RuntimeValue] {
        if case .native(let any) = data, let range = any as? Range<Int> {
            return range.map { .native($0) }
        }
        if let array = data.arrayValue {
            return array
        }
        throw RuntimeError(message: "ForEach needs a range or an array, got \(data.stringified)")
    }
}
