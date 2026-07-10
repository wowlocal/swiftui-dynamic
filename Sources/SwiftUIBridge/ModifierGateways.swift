import SwiftUI
import SwiftInterpreter

/// Modifier gateways applied to view values. Most convert the receiver to
/// `AnyView` first; shape/image-typed modifiers (`.fill`, `.resizable`) check
/// the receiver's box type instead.
extension ViewRegistry {
    func registerModifiers() {
        registerTypedModifiers()

        // MARK: Spacing & sizing

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

        register("frame") { view, args, _ in
            let width = try args.labeled("width").map(Coerce.cgFloat)
            let height = try args.labeled("height").map(Coerce.cgFloat)
            let minWidth = try args.labeled("minWidth").map(Coerce.cgFloat)
            let minHeight = try args.labeled("minHeight").map(Coerce.cgFloat)
            let maxWidth = try args.labeled("maxWidth").map(Coerce.cgFloat)
            let maxHeight = try args.labeled("maxHeight").map(Coerce.cgFloat)
            let alignment = try args.labeled("alignment").map(Coerce.alignment) ?? .center

            var result = view
            if width != nil || height != nil {
                result = AnyView(result.frame(width: width, height: height, alignment: alignment))
            }
            if minWidth != nil || minHeight != nil || maxWidth != nil || maxHeight != nil {
                result = AnyView(result.frame(
                    minWidth: minWidth, maxWidth: maxWidth,
                    minHeight: minHeight, maxHeight: maxHeight,
                    alignment: alignment
                ))
            }
            if width == nil && height == nil && minWidth == nil && minHeight == nil && maxWidth == nil && maxHeight == nil {
                throw RuntimeError(message: ".frame needs width/height/min/max arguments")
            }
            return result
        }

        register("fixedSize") { view, args, _ in
            if let horizontal = args.labeled("horizontal")?.boolValue,
               let vertical = args.labeled("vertical")?.boolValue {
                return AnyView(view.fixedSize(horizontal: horizontal, vertical: vertical))
            }
            return AnyView(view.fixedSize())
        }

        register("layoutPriority") { view, args, _ in
            AnyView(view.layoutPriority(try Coerce.double(args.positional(0) ?? .native(0.0))))
        }
        register("zIndex") { view, args, _ in
            AnyView(view.zIndex(try Coerce.double(args.positional(0) ?? .native(0.0))))
        }
        register("offset") { view, args, _ in
            let x = try args.labeled("x").map(Coerce.cgFloat) ?? 0
            let y = try args.labeled("y").map(Coerce.cgFloat) ?? 0
            return AnyView(view.offset(x: x, y: y))
        }
        register("ignoresSafeArea") { view, _, _ in AnyView(view.ignoresSafeArea()) }

        // MARK: Text styling

        register("font") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".font needs an argument") }
            return AnyView(view.font(try Coerce.font(value)))
        }
        register("bold") { view, _, _ in AnyView(view.bold()) }
        register("italic") { view, _, _ in AnyView(view.italic()) }
        register("monospaced") { view, _, _ in AnyView(view.monospaced()) }
        register("strikethrough") { view, _, _ in AnyView(view.strikethrough()) }
        register("underline") { view, _, _ in AnyView(view.underline()) }
        register("fontWeight") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".fontWeight needs an argument") }
            return AnyView(view.fontWeight(try Coerce.fontWeight(value)))
        }
        register("lineLimit") { view, args, _ in
            AnyView(view.lineLimit(args.positional(0)?.intValue))
        }
        register("multilineTextAlignment") { view, args, _ in
            AnyView(view.multilineTextAlignment(try Coerce.textAlignment(args.positional(0) ?? .implicitMember("leading"))))
        }
        register("minimumScaleFactor") { view, args, _ in
            AnyView(view.minimumScaleFactor(try Coerce.cgFloat(args.positional(0) ?? .native(1.0))))
        }
        register("imageScale") { view, args, _ in
            AnyView(view.imageScale(try Coerce.imageScale(args.positional(0) ?? .implicitMember("medium"))))
        }

        // MARK: Color & effects

        let foreground: @MainActor (AnyView, CallArguments, EvalContext) throws -> AnyView = { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: "missing style argument") }
            return AnyView(view.foregroundStyle(try Coerce.shapeStyle(value)))
        }
        register("foregroundStyle", foreground)
        register("foregroundColor", foreground)

        register("background") { [unowned self] view, args, ctx in
            if let closure = args.firstUnlabeledClosure {
                let views = try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
                let content = views.count == 1 ? views[0] : AnyView(ZStack { Self.indexed(views) })
                return AnyView(view.background(content))
            }
            guard let first = args.positional(0) else {
                throw RuntimeError(message: ".background needs a style or view")
            }
            if let style = try? Coerce.shapeStyle(first) {
                if let shapeArg = args.labeled("in") {
                    return AnyView(view.background(style, in: try Coerce.shape(shapeArg)))
                }
                return AnyView(view.background(style))
            }
            return AnyView(view.background(try self.anyViewResolving(first, ctx)))
        }

        register("overlay") { [unowned self] view, args, ctx in
            let alignment = try args.labeled("alignment").map(Coerce.alignment) ?? .center
            if let closure = args.firstUnlabeledClosure {
                let views = try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
                let content = views.count == 1 ? views[0] : AnyView(ZStack { Self.indexed(views) })
                return AnyView(view.overlay(alignment: alignment) { content })
            }
            guard let first = args.positional(0) else {
                throw RuntimeError(message: ".overlay needs a view")
            }
            let content = try self.anyViewResolving(first, ctx)
            return AnyView(view.overlay(alignment: alignment) { content })
        }

        register("shadow") { view, args, _ in
            let radius = try Coerce.cgFloat(args.labeled("radius") ?? .native(4))
            let color = try args.labeled("color").map(Coerce.color) ?? Color.black.opacity(0.33)
            let x = try args.labeled("x").map(Coerce.cgFloat) ?? 0
            let y = try args.labeled("y").map(Coerce.cgFloat) ?? 0
            return AnyView(view.shadow(color: color, radius: radius, x: x, y: y))
        }

        register("cornerRadius") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".cornerRadius needs a radius") }
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: try Coerce.cgFloat(value))))
        }
        register("clipShape") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".clipShape needs a shape") }
            return AnyView(view.clipShape(try Coerce.shape(value)))
        }
        register("clipped") { view, _, _ in AnyView(view.clipped()) }

        register("border") { view, args, _ in
            guard let style = args.positional(0) else { throw RuntimeError(message: ".border needs a style") }
            let width = try args.labeled("width").map(Coerce.cgFloat) ?? 1
            return AnyView(view.border(try Coerce.shapeStyle(style), width: width))
        }

        register("opacity") { view, args, _ in
            AnyView(view.opacity(try Coerce.double(args.positional(0) ?? .native(1.0))))
        }
        register("blur") { view, args, _ in
            AnyView(view.blur(radius: try Coerce.cgFloat(args.labeled("radius") ?? args.positional(0) ?? .native(0))))
        }
        register("grayscale") { view, args, _ in
            AnyView(view.grayscale(try Coerce.double(args.positional(0) ?? .native(0.0))))
        }
        register("brightness") { view, args, _ in
            AnyView(view.brightness(try Coerce.double(args.positional(0) ?? .native(0.0))))
        }
        register("saturation") { view, args, _ in
            AnyView(view.saturation(try Coerce.double(args.positional(0) ?? .native(1.0))))
        }
        register("tint") { view, args, _ in
            AnyView(view.tint(try Coerce.color(args.positional(0) ?? .implicitMember("accentColor"))))
        }

        // MARK: Geometry & animation

        register("scaleEffect") { view, args, _ in
            AnyView(view.scaleEffect(try Coerce.cgFloat(args.positional(0) ?? .native(1.0))))
        }
        register("rotationEffect") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".rotationEffect needs an angle") }
            return AnyView(view.rotationEffect(try Coerce.angle(value)))
        }
        register("aspectRatio") { view, args, _ in
            let mode = try Coerce.contentMode(args.labeled("contentMode") ?? .implicitMember("fit"))
            if let ratio = try args.positional(0).map(Coerce.cgFloat) {
                return AnyView(view.aspectRatio(ratio, contentMode: mode))
            }
            return AnyView(view.aspectRatio(contentMode: mode))
        }
        register("scaledToFit") { view, _, _ in AnyView(view.scaledToFit()) }
        register("scaledToFill") { view, _, _ in AnyView(view.scaledToFill()) }

        register("animation") { view, args, _ in
            let animation = try args.positional(0).map(Coerce.animation) ?? .default
            // `value:` is stringified — it changes whenever the state it
            // depends on changes, which is what retriggers the animation.
            let value = args.labeled("value")?.stringified ?? ""
            return AnyView(view.animation(animation, value: value))
        }

        register("contentTransition") { view, args, _ in
            guard let value = args.positional(0) else {
                throw RuntimeError(message: ".contentTransition needs a transition")
            }
            let transition: ContentTransition
            switch value {
            case .implicitMember("opacity"):
                transition = .opacity
            case .implicitMember("interpolate"):
                transition = .interpolate
            case .implicitMember("identity"):
                transition = .identity
            case .host(let any):
                guard let call = any as? ImplicitMemberCall, call.name == "numericText" else {
                    throw RuntimeError(message: "unsupported content transition")
                }
                let countsDown = call.arguments.labeled("countsDown")?.boolValue ?? false
                transition = .numericText(countsDown: countsDown)
            default:
                throw RuntimeError(message: "expected .numericText(), .opacity, .interpolate, or .identity")
            }
            return AnyView(view.contentTransition(transition))
        }

        register("transition") { view, _, _ in view } // accepted, ignored in v1

        // MARK: Events

        register("onAppear") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.onAppear { _ = try? ctx.callClosure(closure, arguments: []) })
        }
        register("onDisappear") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.onDisappear { _ = try? ctx.callClosure(closure, arguments: []) })
        }
        register("onTapGesture") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.onTapGesture { _ = try? ctx.callClosure(closure, arguments: []) })
        }
        register("onSubmit") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.onSubmit { _ = try? ctx.callClosure(closure, arguments: []) })
        }
        // Metal flattening with an explicit color mode (2048's board).
        register("drawingGroup") { view, args, _ in
            let opaque = args.labeled("opaque")?.boolValue ?? false
            let colorMode: ColorRenderingMode = switch args.labeled("colorMode") {
            case .implicitMember("linear"): .linear
            case .implicitMember("extendedLinear"): .extendedLinear
            default: .nonLinear
            }
            return AnyView(view.drawingGroup(opaque: opaque, colorMode: colorMode))
        }
        // Deprecated alias of ignoresSafeArea(edges:) — pervasive in
        // pre-iOS-14 corpus projects (Filled, damus).
        register("edgesIgnoringSafeArea") { view, args, _ in
            let edges = try args.positional(0).map(Coerce.edgeSet) ?? .all
            return AnyView(view.ignoresSafeArea(.all, edges: edges))
        }
        // `.gesture(drag, including: .all)` — the `including:` mask is
        // accepted and ignored; unknown gesture kinds attach nothing.
        for gestureModifier in ["gesture", "simultaneousGesture", "highPriorityGesture"] {
            register(gestureModifier) { view, args, ctx in
                guard case .host(let any)? = args.positional(0),
                      let gesture = any as? GestureBox else {
                    return view
                }
                return gesture.attach(to: view, ctx: ctx)
            }
        }
        register("task") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.task { _ = try? ctx.callClosure(closure, arguments: []) })
        }
        register("onReceive") { view, args, ctx in
            guard case .host(let any)? = args.positional(0), let box = any as? TimerPublisherBox else {
                throw RuntimeError(message: ".onReceive supports Timer publishers (Timer.publish(...).autoconnect())")
            }
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.onReceive(box.publisher) { date in
                _ = try? ctx.callClosure(closure, arguments: [.native(date)])
            })
        }

        // MARK: Container configuration

        register("navigationTitle") { view, args, _ in
            AnyView(view.navigationTitle(args.positional(0)?.stringValue ?? ""))
        }

        // MARK: Environment & presentation

        register("environmentObject") { view, args, _ in
            guard case .instance(let model)? = args.positional(0) else {
                throw RuntimeError(message: ".environmentObject needs a model instance")
            }
            return AnyView(view.transformEnvironment(\.interpretedModels) { environment in
                environment.models[model.symbol.name] = model
            })
        }

        // Observation's `.environment(model)` — same carrier as
        // .environmentObject, keyed by type name for @Environment(Type.self).
        register("environment") { view, args, _ in
            // `.environment(\\.isCompact, true)` — custom-key writes pass
            // through for now: subtrees read their @Entry defaults (the
            // fresh-canvas reading). Model injection below stays live.
            if case .host(let any)? = args.positional(0), any is KeyPathStub {
                return AnyView(view)
            }
            guard case .instance(let model)? = args.positional(0), args.arguments.count == 1 else {
                throw RuntimeError(
                    message: ".environment supports the (model) form; \\.keyPath writes aren't supported yet")
            }
            return AnyView(view.transformEnvironment(\.interpretedModels) { environment in
                environment.models[model.symbol.name] = model
            })
        }

        register("tabViewStyle") { view, args, _ in
            // macOS knows automatic/sidebarAdaptable/grouped; iOS-only
            // styles (.page) pass through unchanged.
            if case .implicitMember(let style)? = args.positional(0) {
                switch style {
                case "sidebarAdaptable":
                    if #available(macOS 15.0, *) {
                        return AnyView(view.tabViewStyle(.sidebarAdaptable))
                    }
                case "grouped":
                    if #available(macOS 15.0, *) {
                        return AnyView(view.tabViewStyle(.grouped))
                    }
                case "automatic":
                    return AnyView(view.tabViewStyle(.automatic))
                default: break
                }
            }
            return AnyView(view)
        }

        register("sheet") { view, args, ctx in
            // `sheet(item: $selection) { item in … }` — presents while the
            // item binding is non-nil; content builds at presentation time
            // with the then-current item.
            if let item = args.labeled("item"),
               case .host(let any) = item, let stub = any as? BindingStub {
                guard let closure = args.closure(labeled: "content") ?? args.firstUnlabeledClosure else {
                    throw RuntimeError(message: ".sheet needs a content closure")
                }
                let isPresented = Binding<Bool>(
                    get: { !stub.box.value.isNil },
                    set: { presented in if !presented { stub.box.value = .nilValue } }
                )
                return AnyView(view.sheet(isPresented: isPresented) {
                    if let views = try? ctx.callBuilderClosure(closure, arguments: [stub.box.value]).map(Self.anyView) {
                        if views.count == 1 { views[0] } else { AnyView(VStack { Self.indexed(views) }) }
                    }
                })
            }
            guard let isPresented = args.labeled("isPresented") else {
                throw RuntimeError(message: ".sheet needs isPresented:")
            }
            let binding = try Coerce.boolBinding(isPresented)
            guard let closure = args.closure(labeled: "content") ?? args.firstUnlabeledClosure else {
                throw RuntimeError(message: ".sheet needs a content closure")
            }
            let views = try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
            let content = views.count == 1 ? views[0] : AnyView(VStack { Self.indexed(views) })
            return AnyView(view.sheet(isPresented: binding) { content })
        }

        register("alert") { view, args, ctx in
            let title = args.positional(0)?.stringValue ?? ""
            guard let isPresented = args.labeled("isPresented") else {
                throw RuntimeError(message: ".alert needs isPresented:")
            }
            let binding = try Coerce.boolBinding(isPresented)
            let actionViews = try (args.closure(labeled: "actions") ?? args.firstUnlabeledClosure)
                .map { try ctx.callBuilderClosure($0, arguments: []).map(Self.anyView) } ?? []
            let messageViews = try args.closure(labeled: "message")
                .map { try ctx.callBuilderClosure($0, arguments: []).map(Self.anyView) } ?? []
            if let message = messageViews.first {
                return AnyView(view.alert(title, isPresented: binding,
                                          actions: { Self.indexed(actionViews) },
                                          message: { message }))
            }
            return AnyView(view.alert(title, isPresented: binding) { Self.indexed(actionViews) })
        }

        register("confirmationDialog") { view, args, ctx in
            let title = args.positional(0)?.stringValue ?? ""
            guard let isPresented = args.labeled("isPresented") else {
                throw RuntimeError(message: ".confirmationDialog needs isPresented:")
            }
            let binding = try Coerce.boolBinding(isPresented)
            let actionViews = try (args.closure(labeled: "actions") ?? args.firstUnlabeledClosure)
                .map { try ctx.callBuilderClosure($0, arguments: []).map(Self.anyView) } ?? []
            return AnyView(view.confirmationDialog(title, isPresented: binding) { Self.indexed(actionViews) })
        }

        register("tabItem") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            let views = try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
            let label = views.count == 1 ? views[0] : AnyView(VStack { Self.indexed(views) })
            return AnyView(view.tabItem { label })
        }
        register("tag") { view, args, _ in
            let value = args.positional(0)
            return AnyView(view.tag(value?.stringValue ?? value?.stringified ?? ""))
        }
        register("disabled") { view, args, _ in
            AnyView(view.disabled(args.positional(0)?.boolValue ?? false))
        }
        register("labelsHidden") { view, _, _ in AnyView(view.labelsHidden()) }
        register("id") { view, args, _ in
            let value = args.positional(0)
            return AnyView(view.id(value?.stringValue ?? value?.stringified ?? ""))
        }

        register("listStyle") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "plain": return AnyView(view.listStyle(.plain))
            case "inset": return AnyView(view.listStyle(.inset))
            case "sidebar": return AnyView(view.listStyle(.sidebar))
            case "bordered": return AnyView(view.listStyle(.bordered))
            default: return AnyView(view.listStyle(.automatic))
            }
        }
        register("buttonStyle") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "bordered": return AnyView(view.buttonStyle(.bordered))
            case "borderedProminent": return AnyView(view.buttonStyle(.borderedProminent))
            case "plain": return AnyView(view.buttonStyle(.plain))
            case "borderless": return AnyView(view.buttonStyle(.borderless))
            case "link": return AnyView(view.buttonStyle(.link))
            default: return AnyView(view.buttonStyle(.automatic))
            }
        }
        register("pickerStyle") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "segmented": return AnyView(view.pickerStyle(.segmented))
            case "menu": return AnyView(view.pickerStyle(.menu))
            case "inline": return AnyView(view.pickerStyle(.inline))
            case "radioGroup": return AnyView(view.pickerStyle(.radioGroup))
            default: return AnyView(view.pickerStyle(.automatic))
            }
        }
        register("textFieldStyle") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "roundedBorder": return AnyView(view.textFieldStyle(.roundedBorder))
            case "plain": return AnyView(view.textFieldStyle(.plain))
            case "squareBorder": return AnyView(view.textFieldStyle(.squareBorder))
            default: return AnyView(view.textFieldStyle(.automatic))
            }
        }
        register("controlSize") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "mini": return AnyView(view.controlSize(.mini))
            case "small": return AnyView(view.controlSize(.small))
            case "large": return AnyView(view.controlSize(.large))
            case "extraLarge": return AnyView(view.controlSize(.extraLarge))
            default: return AnyView(view.controlSize(.regular))
            }
        }
    }

    /// Shape- and image-typed modifiers that must see the raw box, not AnyView.
    private func registerTypedModifiers() {
        modifiers["fill"] = HostModifier(name: "fill") { value, args, _ in
            var shapeBox: ShapeBox?
            if case .host(let any) = value { shapeBox = any as? ShapeBox ?? (any as? PathDrawStub).map { ShapeBox($0.path) } }
            guard let box = shapeBox else {
                throw RuntimeError(message: ".fill applies to shapes like Circle()")
            }
            let style = try Coerce.shapeStyle(args.positional(0) ?? .implicitMember("primary"))
            return .native(AnyView(box.shape.fill(style)))
        }
        modifiers["stroke"] = HostModifier(name: "stroke") { value, args, _ in
            var shapeBox: ShapeBox?
            if case .host(let any) = value { shapeBox = any as? ShapeBox ?? (any as? PathDrawStub).map { ShapeBox($0.path) } }
            guard let box = shapeBox else {
                throw RuntimeError(message: ".stroke applies to shapes like Circle()")
            }
            let style = try Coerce.shapeStyle(args.positional(0) ?? .implicitMember("primary"))
            let lineWidth = try args.labeled("lineWidth").map(Coerce.cgFloat) ?? 1
            return .native(AnyView(box.shape.stroke(style, lineWidth: lineWidth)))
        }
        modifiers["trim"] = HostModifier(name: "trim") { value, args, _ in
            guard case .host(let any) = value, let box = any as? ShapeBox else {
                throw RuntimeError(message: ".trim applies to shapes")
            }
            let from = try Coerce.cgFloat(args.labeled("from") ?? .native(0.0))
            let to = try Coerce.cgFloat(args.labeled("to") ?? .native(1.0))
            return .native(ShapeBox(box.shape.trim(from: from, to: to)))
        }
        modifiers["resizable"] = HostModifier(name: "resizable") { value, _, _ in
            guard case .host(let any) = value, let box = any as? ImageBox else {
                throw RuntimeError(message: ".resizable applies to Image")
            }
            return .native(ImageBox(box.image.resizable()))
        }
    }

    private func register(_ name: String, _ transform: @escaping @MainActor (AnyView, CallArguments, EvalContext) throws -> AnyView) {
        modifiers[name] = HostModifier(name: name) { value, args, ctx in
            .native(try transform(try Self.anyView(value), args, ctx))
        }
    }
}
