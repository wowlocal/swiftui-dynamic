import SwiftUI
import SwiftInterpreter

/// Constructor gateways. Each accepts dynamic arguments and calls the real
/// SwiftUI initializer — the interpreter knows nothing about any of them.
extension ViewRegistry {
    func registerViews() {
        // MARK: Text & symbols

        constructors["Text"] = HostFunction(name: "Text") { args, _ in
            guard let value = args.positional(0) else {
                throw RuntimeError(message: "Text needs a string argument")
            }
            if case .host(let any) = value, let box = any as? AttributedStringBox {
                return .native(AnyView(Text(box.attributed)))
            }
            // Unknowables read "" (fresh-string doctrine) — marker dumps
            // must never reach rendered Text.
            if case .host(let any) = value,
               any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                return .native(AnyView(Text("")))
            }
            if case .hostFunction = value { return .native(AnyView(Text(""))) }
            if case .implicitMember = value { return .native(AnyView(Text(""))) }
            return .native(AnyView(Text(value.stringValue ?? value.stringified)))
        }

        constructors["Image"] = HostFunction(name: "Image") { args, _ in
            guard let name = args.labeled("systemName")?.stringValue else {
                throw RuntimeError(message: "only Image(systemName:) is supported")
            }
            return .native(ImageBox(Image(systemName: name)))
        }

        constructors["Label"] = HostFunction(name: "Label") { args, _ in
            guard let title = args.positional(0), let icon = args.labeled("systemImage")?.stringValue else {
                throw RuntimeError(message: "Label needs a title and systemImage:")
            }
            return .native(AnyView(Label(title.stringValue ?? title.stringified, systemImage: icon)))
        }

        constructors["AnyView"] = HostFunction(name: "AnyView") { [unowned self] args, ctx in
            guard let value = args.positional(0) else {
                throw RuntimeError(message: "AnyView needs a view")
            }
            return .native(try self.anyViewResolving(value, ctx))
        }

        constructors["Spacer"] = HostFunction(name: "Spacer") { _, _ in
            .native(AnyView(Spacer()))
        }

        constructors["Divider"] = HostFunction(name: "Divider") { _, _ in
            .native(AnyView(Divider()))
        }

        constructors["ProgressView"] = HostFunction(name: "ProgressView") { args, _ in
            if let value = args.labeled("value") {
                let total = try Coerce.double(args.labeled("total") ?? .native(1.0))
                return .native(AnyView(ProgressView(value: try Coerce.double(value), total: total)))
            }
            if let title = args.positional(0)?.stringValue {
                return .native(AnyView(ProgressView(title)))
            }
            return .native(AnyView(ProgressView()))
        }

        // MARK: Shapes & gradients

        constructors["Circle"] = HostFunction(name: "Circle") { _, _ in .native(ShapeBox(Circle())) }
        constructors["UnevenRoundedRectangle"] = HostFunction(name: "UnevenRoundedRectangle") { args, _ in
            .native(ShapeBox(UnevenRoundedRectangle(
                topLeadingRadius: (try? Coerce.cgFloat(args.labeled("topLeadingRadius") ?? .native(0))) ?? 0,
                bottomLeadingRadius: (try? Coerce.cgFloat(args.labeled("bottomLeadingRadius") ?? .native(0))) ?? 0,
                bottomTrailingRadius: (try? Coerce.cgFloat(args.labeled("bottomTrailingRadius") ?? .native(0))) ?? 0,
                topTrailingRadius: (try? Coerce.cgFloat(args.labeled("topTrailingRadius") ?? .native(0))) ?? 0
            )))
        }
        constructors["Ellipse"] = HostFunction(name: "Ellipse") { _, _ in .native(ShapeBox(Ellipse())) }
        constructors["Rectangle"] = HostFunction(name: "Rectangle") { _, _ in .native(ShapeBox(Rectangle())) }
        constructors["Capsule"] = HostFunction(name: "Capsule") { _, _ in .native(ShapeBox(Capsule())) }
        constructors["RoundedRectangle"] = HostFunction(name: "RoundedRectangle") { args, _ in
            let radius = try Coerce.cgFloat(args.labeled("cornerRadius") ?? .native(8))
            return .native(ShapeBox(RoundedRectangle(cornerRadius: radius)))
        }

        constructors["LinearGradient"] = HostFunction(name: "LinearGradient") { args, _ in
            guard let colorsArg = args.labeled("colors")?.arrayValue else {
                throw RuntimeError(message: "LinearGradient needs colors: [...]")
            }
            let colors = try colorsArg.map(Coerce.color)
            let start = try Coerce.unitPoint(args.labeled("startPoint") ?? .implicitMember("top"))
            let end = try Coerce.unitPoint(args.labeled("endPoint") ?? .implicitMember("bottom"))
            // Raw, not AnyView-wrapped: it must stay usable as a ShapeStyle
            // (`.fill(...)`) and converts to a view lazily in anyView().
            return .native(LinearGradient(colors: colors, startPoint: start, endPoint: end))
        }

        // MARK: Stacks & containers

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

        constructors["Group"] = HostFunction(name: "Group") { args, ctx in
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(Group { Self.indexed(content) }))
        }

        constructors["TabView"] = HostFunction(name: "TabView") { args, ctx in
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(TabView { Self.indexed(content) }))
        }

        constructors["ScrollView"] = HostFunction(name: "ScrollView") { args, ctx in
            var axes: Axis.Set = .vertical
            if case .implicitMember(let name)? = args.positional(0) {
                axes = name == "horizontal" ? .horizontal : .vertical
            }
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(ScrollView(axes) { Self.indexed(content) }))
        }

        constructors["List"] = HostFunction(name: "List") { args, ctx in
            let content = try Self.dataOrPlainContent(args, ctx)
            return .native(AnyView(List { Self.indexed(content) }))
        }

        constructors["Form"] = HostFunction(name: "Form") { args, ctx in
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(Form { Self.indexed(content) }))
        }

        constructors["Section"] = HostFunction(name: "Section") { args, ctx in
            let content = try Self.builderContent(args, ctx)
            var header: AnyView?
            if let headerClosure = args.closure(labeled: "header") {
                let views = try ctx.callBuilderClosure(headerClosure, arguments: []).map(Self.anyView)
                header = views.first
            } else if let title = args.positional(0)?.stringValue {
                header = AnyView(Text(title))
            }
            if let header {
                return .native(AnyView(Section { Self.indexed(content) } header: { header }))
            }
            return .native(AnyView(Section { Self.indexed(content) }))
        }

        constructors["LazyVGrid"] = HostFunction(name: "LazyVGrid") { args, ctx in
            guard let columns = args.labeled("columns") else {
                throw RuntimeError(message: "LazyVGrid needs columns: [GridItem]")
            }
            let spacing = try args.labeled("spacing").map(Coerce.cgFloat)
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(
                LazyVGrid(columns: try Coerce.gridItems(columns), spacing: spacing) { Self.indexed(content) }
            ))
        }

        constructors["LazyHGrid"] = HostFunction(name: "LazyHGrid") { args, ctx in
            guard let rows = args.labeled("rows") else {
                throw RuntimeError(message: "LazyHGrid needs rows: [GridItem]")
            }
            let spacing = try args.labeled("spacing").map(Coerce.cgFloat)
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(
                LazyHGrid(rows: try Coerce.gridItems(rows), spacing: spacing) { Self.indexed(content) }
            ))
        }

        constructors["GridItem"] = HostFunction(name: "GridItem") { args, _ in
            let size = try args.positional(0).map(Coerce.gridItemSize) ?? .flexible()
            let spacing = try args.labeled("spacing").map(Coerce.cgFloat)
            return .native(GridItem(size, spacing: spacing))
        }

        constructors["EdgeInsets"] = HostFunction(name: "EdgeInsets") { args, _ in
            .native(EdgeInsets(
                top: try args.labeled("top").map(Coerce.cgFloat) ?? 0,
                leading: try args.labeled("leading").map(Coerce.cgFloat) ?? 0,
                bottom: try args.labeled("bottom").map(Coerce.cgFloat) ?? 0,
                trailing: try args.labeled("trailing").map(Coerce.cgFloat) ?? 0
            ))
        }

        constructors["Gradient"] = HostFunction(name: "Gradient") { args, _ in
            guard let colors = args.labeled("colors")?.arrayValue else {
                throw RuntimeError(message: "Gradient needs colors: [...]")
            }
            return .native(Gradient(colors: try colors.map(Coerce.color)))
        }

        // MARK: Navigation

        let navigationStack = HostFunction(name: "NavigationStack") { args, ctx in
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(NavigationStack { Self.indexed(content) }))
        }
        constructors["NavigationStack"] = navigationStack
        constructors["NavigationView"] = navigationStack // old samples

        constructors["NavigationLink"] = HostFunction(name: "NavigationLink") { [unowned self] args, ctx in
            let destination: AnyView
            if let value = args.labeled("destination") {
                if let closure = value.closureValue {
                    let views = try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
                    destination = views.count == 1 ? views[0] : AnyView(VStack { Self.indexed(views) })
                } else {
                    destination = try self.anyViewResolving(value, ctx)
                }
            } else if let closure = args.firstUnlabeledClosure, args.positional(0)?.stringValue != nil {
                let views = try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
                destination = views.count == 1 ? views[0] : AnyView(VStack { Self.indexed(views) })
            } else {
                throw RuntimeError(message: "NavigationLink needs a destination")
            }

            if let labelClosure = args.closure(labeled: "label") {
                let views = try ctx.callBuilderClosure(labelClosure, arguments: []).map(Self.anyView)
                let label = views.count == 1 ? views[0] : AnyView(HStack { Self.indexed(views) })
                return .native(AnyView(NavigationLink(destination: destination) { label }))
            }
            let title = args.positional(0)?.stringValue ?? "Link"
            return .native(AnyView(NavigationLink(title, destination: destination)))
        }

        // Component colors — the custom-palette idiom (2048's tiles, most
        // Kavsoft backgrounds). A real Color, so it works in view position,
        // .fill/.background, and .opacity chains alike.
        constructors["Color"] = HostFunction(name: "Color") { args, _ in
            let component: (String) -> Double? = { args.labeled($0)?.doubleValue }
            let opacity = component("opacity") ?? 1.0
            if let red = component("red"), let green = component("green"), let blue = component("blue") {
                return .native(Color(red: red, green: green, blue: blue, opacity: opacity))
            }
            if let white = component("white") {
                return .native(Color(white: white, opacity: opacity))
            }
            if let hue = component("hue"), let saturation = component("saturation"),
               let brightness = component("brightness") {
                return .native(Color(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity))
            }
            // `Color("AssetName")` — real SwiftUI semantics: missing catalog
            // entries resolve to clear (with a console warning), present ones
            // would need the app bundle we don't have.
            if let name = args.positional(0)?.stringValue {
                return .native(Color(name))
            }
            throw RuntimeError(message: "no matching initializer for Color(…) — argument types or labels don't fit")
        }

        // Gestures: interpreted chains applied for real by `.gesture`.
        constructors["DragGesture"] = HostFunction(name: "DragGesture") { args, _ in
            .native(GestureBox(kind: .drag(
                minimumDistance: args.labeled("minimumDistance")?.doubleValue ?? 10)))
        }
        constructors["TapGesture"] = HostFunction(name: "TapGesture") { _, _ in
            .native(GestureBox(kind: .tap))
        }

        // MARK: Controls

        constructors["Button"] = HostFunction(name: "Button") { args, ctx in
            let title = args.positional(0)?.stringValue
            let unlabeled = args.unlabeledClosures

            let actionClosure: ClosureValue?
            let labelClosure: ClosureValue?
            if let labeled = args.closure(labeled: "action") {
                actionClosure = labeled
                labelClosure = args.closure(labeled: "label") ?? unlabeled.first
            } else {
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

            var role: ButtonRole?
            if case .implicitMember(let roleName)? = args.labeled("role") {
                switch roleName {
                case "destructive": role = .destructive
                case "cancel": role = .cancel
                default: throw RuntimeError(message: "unknown button role '.\(roleName)'")
                }
            }
            let action = { _ = try? ctx.callClosure(actionClosure, arguments: []) }
            return .native(AnyView(Button(role: role, action: action) { label }))
        }

        constructors["Toggle"] = HostFunction(name: "Toggle") { args, ctx in
            guard let isOn = args.labeled("isOn") else {
                throw RuntimeError(message: "Toggle needs an isOn: binding")
            }
            let binding = try Coerce.boolBinding(isOn)
            if let labelClosure = args.firstUnlabeledClosure ?? args.closure(labeled: "label") {
                let views = try ctx.callBuilderClosure(labelClosure, arguments: []).map(Self.anyView)
                let label = views.count == 1 ? views[0] : AnyView(HStack { Self.indexed(views) })
                return .native(AnyView(Toggle(isOn: binding) { label }))
            }
            let title = args.positional(0)?.stringValue ?? ""
            return .native(AnyView(Toggle(title, isOn: binding)))
        }

        constructors["TextField"] = HostFunction(name: "TextField") { args, _ in
            guard let text = args.labeled("text") else {
                throw RuntimeError(message: "TextField needs a text: binding")
            }
            let title = args.positional(0)?.stringValue ?? ""
            return .native(AnyView(TextField(title, text: try Coerce.stringBinding(text))))
        }

        constructors["SecureField"] = HostFunction(name: "SecureField") { args, _ in
            guard let text = args.labeled("text") else {
                throw RuntimeError(message: "SecureField needs a text: binding")
            }
            let title = args.positional(0)?.stringValue ?? ""
            return .native(AnyView(SecureField(title, text: try Coerce.stringBinding(text))))
        }

        constructors["Slider"] = HostFunction(name: "Slider") { args, _ in
            guard let value = args.labeled("value") else {
                throw RuntimeError(message: "Slider needs a value: binding")
            }
            let binding = try Coerce.doubleBinding(value)
            guard let rangeValue = args.labeled("in") else {
                return .native(AnyView(Slider(value: binding)))
            }
            guard let bounds = rangeValue.doubleRangeValue else {
                throw RuntimeError(message: "Slider(in:) needs a range like 0...10 or 0.01...0.1")
            }
            if let step = args.labeled("step")?.doubleValue {
                return .native(AnyView(Slider(value: binding, in: bounds, step: step)))
            }
            return .native(AnyView(Slider(value: binding, in: bounds)))
        }

        /// String-selection Picker: content views tag with .tag("...") and the
        /// selection binding reads/writes the String state.
        constructors["Picker"] = HostFunction(name: "Picker") { args, ctx in
            guard let selection = args.labeled("selection") else {
                throw RuntimeError(message: "Picker needs a selection: binding")
            }
            let binding = try Coerce.stringBinding(selection)
            let content = try Self.builderContent(args, ctx)
            let title = args.positional(0)?.stringValue ?? ""
            return .native(AnyView(Picker(title, selection: binding) { Self.indexed(content) }))
        }

        // MARK: Iteration & functions

        constructors["ForEach"] = HostFunction(name: "ForEach") { args, ctx in
            guard let data = args.positional(0) else {
                throw RuntimeError(message: "ForEach needs a range or an array")
            }
            guard let content = args.closure(labeled: "content") ?? args.lastUnlabeledClosure else {
                throw RuntimeError(message: "ForEach needs a content closure")
            }
            // `ForEach($items) { $item in … }` — element bindings write back.
            let elements: [RuntimeValue]
            if case .host(let any) = data, let stub = any as? BindingStub,
               let bindings = stub.elementBindings() {
                elements = bindings
            } else {
                elements = try Self.forEachElements(data)
            }
            var views: [AnyView] = []
            for element in elements {
                views += try ctx.callBuilderClosure(content, arguments: [element]).map(Self.anyView)
            }
            return .native(AnyView(Self.indexed(views)))
        }

        constructors["withAnimation"] = HostFunction(name: "withAnimation") { args, ctx in
            guard let closure = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "withAnimation needs a closure")
            }
            let animation = try args.positional(0).map(Coerce.animation) ?? .default
            return try withAnimation(animation) {
                try ctx.callClosure(closure, arguments: [])
            }
        }

        // `withTransaction(Transaction(animation: .spring())) { … }` — how
        // 2048 wraps every move.
        constructors["Transaction"] = HostFunction(name: "Transaction") { args, _ in
            var transaction = Transaction()
            if let animation = args.labeled("animation") {
                transaction.animation = try Coerce.animation(animation)
            }
            if let disables = args.labeled("disablesAnimations")?.boolValue {
                transaction.disablesAnimations = disables
            }
            return .native(transaction)
        }
        constructors["withTransaction"] = HostFunction(name: "withTransaction") { args, ctx in
            guard let closure = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "withTransaction needs a closure")
            }
            guard case .host(let any)? = args.positional(0), let transaction = any as? Transaction else {
                return try ctx.callClosure(closure, arguments: [])
            }
            return try withTransaction(transaction) {
                try ctx.callClosure(closure, arguments: [])
            }
        }
    }

    // MARK: - Shared helpers

    static func forEachElements(_ data: RuntimeValue) throws -> [RuntimeValue] {
        if case .host(let any) = data, let call = any as? ImplicitMemberCall,
           call.name == "init",
           call.arguments.labeled("filter") != nil || call.arguments.labeled("sort") != nil
            || call.arguments.labeled("sortDescriptors") != nil {
            return [] // Query-shaped marker: fresh store
        }
        // Unknowable host collections (GraphQL fragment chains, unresolved
        // statics) iterate EMPTY — the fresh-store reading, same as for-in.
        if case .host(let any) = data,
           any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
            return []
        }
        if case .implicitMember = data { return [] }
        if case .hostFunction = data { return [] } // unresolvable member read
        if case .host(let dataAny) = data, let bytes = dataAny as? Data {
            return bytes.map { .native(Int($0)) } // Data IS a byte collection
        }
        if let range = data.rangeValue {
            return range.map { .native($0) }
        }
        if let array = data.arrayValue {
            return array
        }
        throw RuntimeError(message: "ForEach needs a range or an array, got \(data.stringified)")
    }

    /// `List { … }` and `List(data) { item in … }` both funnel through here.
    static func dataOrPlainContent(_ args: CallArguments, _ ctx: EvalContext) throws -> [AnyView] {
        guard let content = args.closure(labeled: "content") ?? args.lastUnlabeledClosure else {
            throw RuntimeError(message: "missing content closure")
        }
        if let data = args.positional(0), let elements = try? forEachElements(data) {
            var views: [AnyView] = []
            for element in elements {
                views += try ctx.callBuilderClosure(content, arguments: [element]).map(Self.anyView)
            }
            return views
        }
        return try ctx.callBuilderClosure(content, arguments: []).map(Self.anyView)
    }
}
