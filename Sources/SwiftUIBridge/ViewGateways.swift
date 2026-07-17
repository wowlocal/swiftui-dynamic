#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI
import SwiftInterpreter

/// Constructor gateways. Each accepts dynamic arguments and calls the real
/// SwiftUI initializer — the interpreter knows nothing about any of them.
extension ViewRegistry {
    func registerViews() {
        // MARK: Text & symbols

        constructors["Text"] = HostFunction(name: "Text") { args, ctx in
            guard var value = args.positional(0) else {
                throw RuntimeError(message: "Text needs a string argument")
            }
            if case .host(let any) = value, let box = any as? AttributedStringBox {
                return .native(TextBox(Text(box.attributed)))
            }
            // TYPED markers resolve at this boundary (the computed-property
            // laziness contract): `var title: LocalizedStringKey { .init(x) }`
            // reaches Text as an init marker hinted with the property type.
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               let hint = call.typeHint, let interpreter = ctx as? Interpreter {
                value = interpreter.resolveForBridge(value, typeName: hint)
            }
            // Unknowables read "" (fresh-string doctrine) — marker dumps
            // must never reach rendered Text.
            if case .host(let any) = value,
               any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                return .native(TextBox(Text("")))
            }
            if case .hostFunction = value { return .native(TextBox(Text(""))) }
            if case .implicitMember = value { return .native(TextBox(Text(""))) }
            return .native(TextBox(Text(value.stringValue ?? value.stringified)))
        }

        constructors["Image"] = HostFunction(name: "Image") { args, _ in
            if let name = args.labeled("systemName")?.stringValue {
                return .native(ImageBox(Image(systemName: name)))
            }
            if let name = args.positional(0)?.stringValue {
                // `swift run` has no compiled asset catalog. Preserve Image's
                // real named-resource semantics (missing assets render empty)
                // while accepting `bundle: .module` project source.
                return .native(ImageBox(Image(name)))
            }
            throw RuntimeError(message: "Image needs a name or systemName:")
        }

        constructors["Label"] = HostFunction(name: "Label") { args, ctx in
            if let titleClosure = args.closure(labeled: "title") ?? args.firstUnlabeledClosure,
               let iconClosure = args.closure(labeled: "icon") {
                let titleViews = try ctx.callBuilderClosure(titleClosure, arguments: []).map(Self.anyView)
                let iconViews = try ctx.callBuilderClosure(iconClosure, arguments: []).map(Self.anyView)
                let title = titleViews.count == 1
                    ? titleViews[0]
                    : AnyView(HStack { Self.indexed(titleViews) })
                let icon = iconViews.count == 1
                    ? iconViews[0]
                    : AnyView(HStack { Self.indexed(iconViews) })
                return .native(AnyView(Label { title } icon: { icon }))
            }
            guard let title = args.positional(0),
                  let icon = args.labeled("systemImage")?.stringValue else {
                throw RuntimeError(message: "Label needs title/icon builders or a title and systemImage:")
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

        // Swift Charts' ChartContent protocol cannot cross the dynamic
        // AnyView boundary. Keep the chart's layout footprint as a clear
        // renderable surface; chart-specific modifiers are inert gateways.
        constructors["Chart"] = HostFunction(name: "Chart") { _, _ in
            .native(AnyView(Color.clear))
        }

        // MARK: Shapes & gradients

        constructors["Circle"] = HostFunction(name: "Circle") { _, _ in .native(ShapeBox(insettable: Circle())) }
        constructors["UnevenRoundedRectangle"] = HostFunction(name: "UnevenRoundedRectangle") { args, _ in
            .native(ShapeBox(UnevenRoundedRectangle(
                topLeadingRadius: (try? Coerce.cgFloat(args.labeled("topLeadingRadius") ?? .native(0))) ?? 0,
                bottomLeadingRadius: (try? Coerce.cgFloat(args.labeled("bottomLeadingRadius") ?? .native(0))) ?? 0,
                bottomTrailingRadius: (try? Coerce.cgFloat(args.labeled("bottomTrailingRadius") ?? .native(0))) ?? 0,
                topTrailingRadius: (try? Coerce.cgFloat(args.labeled("topTrailingRadius") ?? .native(0))) ?? 0
            )))
        }
        constructors["Ellipse"] = HostFunction(name: "Ellipse") { _, _ in .native(ShapeBox(insettable: Ellipse())) }
        constructors["Rectangle"] = HostFunction(name: "Rectangle") { _, _ in .native(ShapeBox(insettable: Rectangle())) }
        constructors["Capsule"] = HostFunction(name: "Capsule") { _, _ in .native(ShapeBox(insettable: Capsule())) }
        constructors["RoundedRectangle"] = HostFunction(name: "RoundedRectangle") { args, _ in
            let radius = try Coerce.cgFloat(args.labeled("cornerRadius") ?? .native(8))
            let style = Coerce.roundedCornerStyle(args.labeled("style"))
            return .native(ShapeBox(insettable: RoundedRectangle(cornerRadius: radius, style: style)))
        }
        constructors["ContainerRelativeShape"] = HostFunction(name: "ContainerRelativeShape") { _, _ in
            .native(ShapeBox(insettable: ContainerRelativeShape()))
        }

        constructors["AnyShapeStyle"] = HostFunction(name: "AnyShapeStyle") { args, _ in
            guard let style = args.positional(0) else {
                throw RuntimeError(message: "AnyShapeStyle needs a style")
            }
            // Keep the erased style as a real value. Wrapping it as a view or
            // an opaque constructor bag loses ShapeStyle conformance when it
            // later crosses a computed-property or collection boundary.
            return .native(try Coerce.shapeStyle(style))
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

        constructors["GeometryReader"] = HostFunction(name: "GeometryReader") { args, ctx in
            // The content re-evaluates per LAYOUT PASS with the REAL proxy —
            // the InterpretedShape pattern (SwiftUI calls the builder on the
            // main thread during layout, so assumeIsolated holds).
            guard let content = args.firstUnlabeledClosure else {
                throw RuntimeError(message: "GeometryReader needs a content closure")
            }
            guard let interpreter = ctx as? Interpreter else {
                return .native(AnyView(EmptyView()))
            }
            let carrier = GeometryContentCarrier(interpreter: interpreter, content: content)
            return .native(AnyView(GeometryReader { proxy in
                carrier.view(for: proxy)
            }))
        }

        constructors["TableColumn"] = HostFunction(name: "TableColumn") { args, _ in
            // A column SPEC — consumed by the Table gateway below.
            let title = args.positional(0)?.stringValue ?? ""
            var keyPath: KeyPathStub?
            if case .host(let any)? = args.labeled("value"), let stub = any as? KeyPathStub {
                keyPath = stub
            }
            let content = args.arguments.last(where: { $0.value.closureValue != nil })?.value.closureValue
            return .native(TableColumnSpec(title: title, keyPath: keyPath, content: content))
        }

        constructors["TableRow"] = HostFunction(name: "TableRow") { args, _ in
            // Rows-builder marks: the ACTIVE Table gateway collects the row
            // value; the returned view is a placeholder the builder discards.
            TableRowCollector.active?.append(args.positional(0) ?? .void)
            return .native(AnyView(EmptyView()))
        }

        constructors["Table"] = HostFunction(name: "Table") { args, ctx in
            guard let interpreter = ctx as? Interpreter else {
                return .native(AnyView(EmptyView()))
            }
            let closures = args.arguments.filter { $0.value.closureValue != nil }
            guard let columnsClosure = closures.first?.value.closureValue else {
                throw RuntimeError(message: "Table needs a columns builder")
            }
            // Column specs from the DSL.
            let columnValues = try ctx.callBuilderClosure(columnsClosure, arguments: [])
            var specs: [TableColumnSpec] = []
            for value in columnValues {
                if case .host(let any) = value, let spec = any as? TableColumnSpec {
                    specs.append(spec)
                }
            }
            // Row values: `Table(data)` positional, or the rows: builder
            // (TableRow marks collected while it evaluates).
            var rowValues = args.positional(0)?.arrayValue ?? []
            if rowValues.isEmpty,
               let rowsClosure = (args.closure(labeled: "rows") ?? closures.dropFirst().first?.value.closureValue) {
                TableRowCollector.active = []
                _ = try? ctx.callBuilderClosure(rowsClosure, arguments: [])
                rowValues = TableRowCollector.active ?? []
                TableRowCollector.active = nil
            }
            guard !specs.isEmpty else { return .native(AnyView(EmptyView())) }
            let sortBox = args.labeled("sortOrder").flatMap { try? Coerce.bindingBox($0) }
            if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil {
                FileHandle.standardError.write(Data(
                    "TABLE specs=\(specs.map { ($0.title, $0.keyPath?.components) }) rows=\(rowValues.count) sort=\(String(describing: sortBox?.value))\n".utf8))
            }
            return .native(try Self.realTable(
                rows: rowValues, specs: specs, sortOrder: sortBox, interpreter: interpreter))
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
            // Dynamic selection values cannot satisfy the static Hashable
            // generic, so rows tag with their stable stringified identity
            // and the binding hands the app back the ORIGINAL runtime value
            // (NavigationSelectionValues) — a click then re-renders the
            // detail exactly like a programmatic state write.
            if let selectionArg = args.labeled("selection"),
               let box = try? Coerce.bindingBox(selectionArg) {
                let binding = Binding<String?>(
                    get: {
                        if case .nilValue = box.value { return nil }
                        return box.value.stringified
                    },
                    set: { newTag in
                        guard let newTag else {
                            box.value = .nilValue
                            return
                        }
                        box.value = NavigationSelectionValues.byTag[newTag] ?? .string(newTag)
                    }
                )
                return .native(AnyView(List(selection: binding) { Self.indexed(content) }))
            }
            return .native(AnyView(List { Self.indexed(content) }))
        }

        constructors["Form"] = HostFunction(name: "Form") { args, ctx in
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(Form { Self.indexed(content) }))
        }

        constructors["Grid"] = HostFunction(name: "Grid") { args, ctx in
            let alignment = try args.labeled("alignment").map(Coerce.alignment) ?? .center
            let horizontalSpacing = try args.labeled("horizontalSpacing").map(Coerce.cgFloat)
            let verticalSpacing = try args.labeled("verticalSpacing").map(Coerce.cgFloat)
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(Grid(
                alignment: alignment,
                horizontalSpacing: horizontalSpacing,
                verticalSpacing: verticalSpacing
            ) {
                Self.indexed(content)
            }))
        }

        constructors["GridRow"] = HostFunction(name: "GridRow") { args, ctx in
            let alignment = try args.labeled("alignment").map(Coerce.verticalAlignment)
            let content = try Self.builderContent(args, ctx)
            return .native(AnyView(GridRow(alignment: alignment) {
                Self.indexed(content)
            }))
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
            // alignment: was silently dropped — shorter grid cells then
            // CENTER in their row (the donuts-gallery caption drift).
            let alignment = try args.labeled("alignment").map(Coerce.alignment)
            return .native(GridItem(size, spacing: spacing, alignment: alignment))
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
            if args.labeled("path") != nil {
                // A dynamic NavigationPath cannot satisfy NavigationStack's
                // static path element types. Native path hosting can also
                // suppress the initial interpreted root outside its App
                // scene, so preserve that root in a stack-shaped fallback.
                return .native(AnyView(VStack { Self.indexed(content) }))
            }
            return .native(AnyView(NavigationStack { Self.indexed(content) }))
        }
        constructors["NavigationStack"] = navigationStack
        constructors["NavigationView"] = navigationStack // old samples

        constructors["NavigationSplitView"] = HostFunction(name: "NavigationSplitView") { args, ctx in
            guard let sidebarClosure = args.closure(labeled: "sidebar") ?? args.firstUnlabeledClosure else {
                throw RuntimeError(message: "NavigationSplitView needs sidebar content")
            }
            guard let detailClosure = args.closure(labeled: "detail") else {
                throw RuntimeError(message: "NavigationSplitView needs detail content")
            }
            let sidebarValues = try ctx.callBuilderClosure(sidebarClosure, arguments: [])
            let detailValues = try ctx.callBuilderClosure(detailClosure, arguments: [])
            let sidebar = try sidebarValues.map(Self.anyView)
            let detail = try detailValues.map(Self.anyView)
            let sidebarContent = sidebar.count == 1
                ? sidebar[0]
                : AnyView(VStack(alignment: .leading) { Self.indexed(sidebar) })
            let detailContent = detail.count == 1
                ? detail[0]
                : AnyView(VStack(alignment: .leading) { Self.indexed(detail) })
            // Native NavigationSplitView keeps its columns lazy and, when
            // hosted outside the originating App scene, can leave dynamic
            // AnyView columns undiscovered. A split-shaped host fallback
            // keeps both interpreted branches alive and interactive.
            return .native(AnyView(HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    sidebarContent
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    detailContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }))
        }

        constructors["NavigationLink"] = HostFunction(name: "NavigationLink") { [unowned self] args, ctx in
            let labelClosure = args.closure(labeled: "label") ?? args.firstUnlabeledClosure
            if let value = args.labeled("value"), let labelClosure {
                let views = try ctx.callBuilderClosure(labelClosure, arguments: []).map(Self.anyView)
                let label = views.count == 1 ? views[0] : AnyView(HStack { Self.indexed(views) })
                // Dynamic interpreted values cannot satisfy a static generic
                // Hashable constraint. Their stable textual identity keeps the
                // real NavigationLink behavior and rendering intact; the tag
                // makes the row selectable in a List(selection:) and the
                // registry preserves the original value for the write-back.
                let tag = value.stringified
                NavigationSelectionValues.byTag[tag] = value
                return .native(AnyView(NavigationLink(value: tag) { label }.tag(tag)))
            }

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

            if let labelClosure {
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
            if let platformColor = args.labeled("uiColor") ?? args.labeled("nsColor") {
#if canImport(AppKit)
                if case .host(let any) = platformColor, let color = any as? NSColor {
                    return .native(Color(nsColor: color))
                }
                if case .implicitMember(let name) = platformColor {
                    let color: NSColor = switch name {
                    case "systemGray5": .systemGray.withAlphaComponent(0.18)
                    case "systemGray6": .systemGray.withAlphaComponent(0.10)
                    case "lightGray": .lightGray
                    case "tertiarySystemFill", "quaternarySystemFill": .separatorColor
                    case "tertiarySystemBackground": .controlBackgroundColor
                    default: .windowBackgroundColor
                    }
                    return .native(Color(nsColor: color))
                }
                return .native(Color(nsColor: .windowBackgroundColor))
#else
                if case .host(let any) = platformColor, let color = any as? UIColor {
                    return .native(Color(uiColor: color))
                }
                if case .implicitMember(let name) = platformColor {
                    let color: UIColor = switch name {
                    case "systemGray5": .systemGray5
                    case "systemGray6": .systemGray6
                    case "lightGray": .lightGray
                    case "tertiarySystemFill": .tertiarySystemFill
                    case "quaternarySystemFill": .quaternarySystemFill
                    case "tertiarySystemBackground": .tertiarySystemBackground
                    default: .systemBackground
                    }
                    return .native(Color(uiColor: color))
                }
                return .native(Color(uiColor: .systemBackground))
#endif
            }
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
            let callback = InterpretedHostCallback(
                closure: actionClosure,
                context: ctx,
                diagnosticContext: "Button action")
            let action = { callback.call() }
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
            guard let bounds = rangeValue.rangeValue?.closedDoubleRange else {
                throw RuntimeError(message: "Slider(in:) needs a closed range like 0...10 or 0.01...0.1")
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
            var collected: [RuntimeValue] = []
            for element in elements {
                collected += try ctx.callBuilderClosure(content, arguments: [element])
            }
            // Chart-content ForEach yields MARKS, not views — pass the
            // real chart contents through for the Chart builder to splice.
            let chartMarks = Self.chartContents(collected)
            if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil {
                FileHandle.standardError.write(Data(
                    "FOREACH-KINDS elements=\(elements.count) marks=\(chartMarks.count) first=\(collected.first.map { String(describing: $0).prefix(90) } ?? "none")\n".utf8))
            }
            if !chartMarks.isEmpty, chartMarks.count == collected.count {
                return .native(chartMarks)
            }
            if !chartMarks.isEmpty {
                RenderDiagnostics.record(
                    RuntimeError(message: "ForEach mixed chart/view content: \(chartMarks.count) marks of \(collected.count) values; kinds=\(collected.map { String(describing: $0).prefix(60) })"),
                    in: "ForEach")
            }
            let views = try collected.map(Self.anyView)
            if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil {
                FileHandle.standardError.write(Data("FOREACH elements=\(elements.count) views=\(views.count)\n".utf8))
            }
            return .native(ForEachFan(views: views))
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
            guard let values = range.integerValues() else {
                throw RuntimeError(message: "ForEach needs an integer range")
            }
            return values
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

/// Keeps non-Sendable interpreter refs behind an @unchecked wall for
/// GeometryReader's layout-time builder (the InterpretedShape precedent).
private final class GeometryContentCarrier: @unchecked Sendable {
    let interpreter: Interpreter
    let content: ClosureValue

    nonisolated init(interpreter: Interpreter, content: ClosureValue) {
        self.interpreter = interpreter
        self.content = content
    }

    nonisolated func view(for proxy: GeometryProxy) -> AnyView {
        // Void-returning assumeIsolated (AnyView isn't Sendable) — the
        // result rides captured vars; SwiftUI invokes this on main, so the
        // proxy never actually crosses an isolation boundary.
        nonisolated(unsafe) var result = AnyView(EmptyView())
        nonisolated(unsafe) let carriedProxy = proxy
        MainActor.assumeIsolated {
            do {
                let views = try interpreter.callBuilderClosure(content, arguments: [.native(carriedProxy)])
                let children = try views.map { try ViewRegistry.anyView($0) }
                if children.count == 1 {
                    result = children[0]
                } else {
                    result = AnyView(ZStack(alignment: .topLeading) {
                        ForEach(children.indices, id: \.self) { children[$0] }
                    })
                }
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: "GeometryReader")
            } catch {
            }
        }
        return result
    }
}

/// Column spec + rows collector for the Table gateway.
struct TableColumnSpec {
    let title: String
    let keyPath: KeyPathStub?
    let content: ClosureValue?
    // `.width(60)` / `.width(min:ideal:max:)` on the column DSL.
    var fixedWidth: CGFloat?
    var minWidth: CGFloat?
    var idealWidth: CGFloat?
    var maxWidth: CGFloat?

    init(title: String, keyPath: KeyPathStub?, content: ClosureValue?) {
        self.title = title
        self.keyPath = keyPath
        self.content = content
    }
}

/// Host members on the column spec (the DSL's width modifiers).
@MainActor
func tableColumnSpecMember(_ name: String, on value: Any) -> RuntimeValue? {
    guard let spec = value as? TableColumnSpec, name == "width" else { return nil }
    return .hostFunction(HostFunction(name: name) { args, _ in
        var updated = spec
        if let fixed = args.positional(0) {
            updated.fixedWidth = try Coerce.cgFloat(fixed)
        } else {
            updated.minWidth = try args.labeled("min").map(Coerce.cgFloat)
            updated.idealWidth = try args.labeled("ideal").map(Coerce.cgFloat)
            updated.maxWidth = try args.labeled("max").map(Coerce.cgFloat)
        }
        return .native(updated)
    })
}

enum TableRowCollector {
    nonisolated(unsafe) static var active: [RuntimeValue]?
}

/// `NavigationLink(value:)` rows tag with their stable stringified identity;
/// the ORIGINAL runtime values park here so a List selection write can hand
/// the app back the exact value it navigated with.
enum NavigationSelectionValues {
    static var byTag: [String: RuntimeValue] = [:]
}

extension ViewRegistry {
    /// A REAL SwiftUI Table (NSTableView-backed — headers, stripes, row
    /// metrics all native) over PREBUILT interpreted cells. Sorting stays
    /// with the app (it sorts before the Table sees rows).
    struct TableShimRow: Identifiable {
        let id: Int
        // Distinct comparable keys so sortable TableColumns carry per-column
        // identity to the native header; the app still sorts the rows.
        nonisolated var c0: Int { id }
        nonisolated var c1: Int { id }
        nonisolated var c2: Int { id }
        nonisolated var c3: Int { id }
        nonisolated var c4: Int { id }
        nonisolated var c5: Int { id }
    }

    private final class CellGrid: @unchecked Sendable {
        let cells: [[AnyView]]
        init(_ cells: [[AnyView]]) { self.cells = cells }
        func cell(_ row: Int, _ column: Int) -> AnyView {
            guard cells.indices.contains(row), cells[row].indices.contains(column) else {
                return AnyView(EmptyView())
            }
            return cells[row][column]
        }
    }

    static func realTable(
        rows: [RuntimeValue], specs: [TableColumnSpec], sortOrder: Box?,
        interpreter: Interpreter
    ) throws -> AnyView {
        var built: [[AnyView]] = []
        for row in rows {
            var line: [AnyView] = []
            for spec in specs {
                if let content = spec.content {
                    var views: [RuntimeValue] = []
                    do {
                        views = try interpreter.callBuilderClosure(content, arguments: [row])
                    } catch let error as RuntimeError {
                        RenderDiagnostics.record(error, in: "TableColumn(\(spec.title))")
                    } catch {
                    }
                    let anyViews = views.compactMap { try? ViewRegistry.anyView($0) }
                    if anyViews.count == 1 {
                        line.append(anyViews[0])
                    } else if anyViews.isEmpty {
                        line.append(AnyView(EmptyView()))
                    } else {
                        line.append(AnyView(HStack { ForEach(anyViews.indices, id: \.self) { anyViews[$0] } }))
                    }
                } else if let keyPath = spec.keyPath {
                    let value = (try? interpreter.applyKeyPathForBridge(keyPath, to: row)) ?? .void
                    line.append(AnyView(Text(value.stringValue ?? value.stringified)))
                } else {
                    line.append(AnyView(EmptyView()))
                }
            }
            built.append(line)
        }
        let grid = CellGrid(built)
        let shims = rows.indices.map { TableShimRow(id: $0) }
        let titles = specs.map(\.title)
        if let sortBox = sortOrder {
            return sortableTable(
                shims: shims, grid: grid, specs: specs, titles: titles, sortBox: sortBox)
        }
        func sized(_ column: TableColumn<TableShimRow, Never, AnyView, Text>, _ index: Int) -> TableColumn<TableShimRow, Never, AnyView, Text> {
            let spec = specs[index]
            if let fixed = spec.fixedWidth { return column.width(fixed) }
            if spec.minWidth != nil || spec.idealWidth != nil || spec.maxWidth != nil {
                return column.width(min: spec.minWidth, ideal: spec.idealWidth, max: spec.maxWidth)
            }
            return column
        }
        switch specs.count {
        case 1:
            return AnyView(Table(shims) {
                sized(TableColumn(titles[0]) { (r: TableShimRow) in grid.cell(r.id, 0) }, 0)
            })
        case 2:
            return AnyView(Table(shims) {
                sized(TableColumn(titles[0]) { (r: TableShimRow) in grid.cell(r.id, 0) }, 0)
                sized(TableColumn(titles[1]) { (r: TableShimRow) in grid.cell(r.id, 1) }, 1)
            })
        case 3:
            return AnyView(Table(shims) {
                sized(TableColumn(titles[0]) { (r: TableShimRow) in grid.cell(r.id, 0) }, 0)
                sized(TableColumn(titles[1]) { (r: TableShimRow) in grid.cell(r.id, 1) }, 1)
                sized(TableColumn(titles[2]) { (r: TableShimRow) in grid.cell(r.id, 2) }, 2)
            })
        case 4:
            return AnyView(Table(shims) {
                sized(TableColumn(titles[0]) { (r: TableShimRow) in grid.cell(r.id, 0) }, 0)
                sized(TableColumn(titles[1]) { (r: TableShimRow) in grid.cell(r.id, 1) }, 1)
                sized(TableColumn(titles[2]) { (r: TableShimRow) in grid.cell(r.id, 2) }, 2)
                sized(TableColumn(titles[3]) { (r: TableShimRow) in grid.cell(r.id, 3) }, 3)
            })
        case 5:
            return AnyView(Table(shims) {
                sized(TableColumn(titles[0]) { (r: TableShimRow) in grid.cell(r.id, 0) }, 0)
                sized(TableColumn(titles[1]) { (r: TableShimRow) in grid.cell(r.id, 1) }, 1)
                sized(TableColumn(titles[2]) { (r: TableShimRow) in grid.cell(r.id, 2) }, 2)
                sized(TableColumn(titles[3]) { (r: TableShimRow) in grid.cell(r.id, 3) }, 3)
                sized(TableColumn(titles[4]) { (r: TableShimRow) in grid.cell(r.id, 4) }, 4)
            })
        default:
            return AnyView(Table(shims) {
                sized(TableColumn(titles[0]) { (r: TableShimRow) in grid.cell(r.id, 0) }, 0)
                TableColumn(titles.count > 1 ? titles[1] : "") { (r: TableShimRow) in grid.cell(r.id, 1) }
                TableColumn(titles.count > 2 ? titles[2] : "") { (r: TableShimRow) in grid.cell(r.id, 2) }
                TableColumn(titles.count > 3 ? titles[3] : "") { (r: TableShimRow) in grid.cell(r.id, 3) }
                TableColumn(titles.count > 4 ? titles[4] : "") { (r: TableShimRow) in grid.cell(r.id, 4) }
                TableColumn(titles.count > 5 ? titles[5] : "") { (r: TableShimRow) in grid.cell(r.id, 5) }
            })
        }
    }

    /// Sortable Table: the app's `sortOrder` binding (an array of
    /// KeyPathComparatorBox) drives the native header — the sorted column's
    /// bold title + direction chevron — and header clicks write back through
    /// the same box so the app re-sorts its rows. Columns whose spec has no
    /// key path are unsortable in native, so their writes are dropped.
    private static let shimSortPaths: [any KeyPath<TableShimRow, Int> & Sendable] = [
        \.c0, \.c1, \.c2, \.c3, \.c4, \.c5,
    ]

    private static func sortableTable(
        shims: [TableShimRow], grid: CellGrid, specs: [TableColumnSpec],
        titles: [String], sortBox: Box
    ) -> AnyView {
        let paths = shimSortPaths
        func appSort() -> (index: Int, ascending: Bool)? {
            guard case .array(let entries) = sortBox.value, let first = entries.first,
                  case .host(let any) = first, let comparator = any as? KeyPathComparatorBox,
                  let index = specs.firstIndex(where: {
                      $0.keyPath?.components == comparator.keyPath.components
                  }),
                  index < paths.count else { return nil }
            return (index, comparator.ascending)
        }
        let binding = Binding<[KeyPathComparator<TableShimRow>]>(
            get: {
                guard let (index, ascending) = appSort() else { return [] }
                return [KeyPathComparator(paths[index], order: ascending ? .forward : .reverse)]
            },
            set: { newOrder in
                guard let first = newOrder.first,
                      let index = paths.firstIndex(where: {
                          ($0 as PartialKeyPath<TableShimRow>) == first.keyPath
                      }),
                      index < specs.count, let keyPath = specs[index].keyPath else { return }
                sortBox.value = .array([.host(KeyPathComparatorBox(
                    keyPath: keyPath, ascending: first.order == .forward))])
            }
        )
        func sized(
            _ column: TableColumn<TableShimRow, KeyPathComparator<TableShimRow>, AnyView, Text>,
            _ index: Int
        ) -> TableColumn<TableShimRow, KeyPathComparator<TableShimRow>, AnyView, Text> {
            let spec = specs[index]
            if let fixed = spec.fixedWidth { return column.width(fixed) }
            if spec.minWidth != nil || spec.idealWidth != nil || spec.maxWidth != nil {
                return column.width(min: spec.minWidth, ideal: spec.idealWidth, max: spec.maxWidth)
            }
            return column
        }
        func col(_ index: Int) -> TableColumn<TableShimRow, KeyPathComparator<TableShimRow>, AnyView, Text> {
            sized(TableColumn(titles[index], sortUsing: KeyPathComparator(paths[index])) {
                (r: TableShimRow) in grid.cell(r.id, index)
            }, index)
        }
        switch specs.count {
        case 1:
            return AnyView(Table(shims, sortOrder: binding) { col(0) })
        case 2:
            return AnyView(Table(shims, sortOrder: binding) { col(0); col(1) })
        case 3:
            return AnyView(Table(shims, sortOrder: binding) { col(0); col(1); col(2) })
        case 4:
            return AnyView(Table(shims, sortOrder: binding) { col(0); col(1); col(2); col(3) })
        case 5:
            return AnyView(Table(shims, sortOrder: binding) { col(0); col(1); col(2); col(3); col(4) })
        default:
            return AnyView(Table(shims, sortOrder: binding) {
                col(0); col(1); col(2); col(3); col(4); col(5)
            })
        }
    }
}
