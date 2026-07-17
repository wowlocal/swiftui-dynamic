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
            let first = args.positional(0)
            let hasEdgeArgument: Bool
            if let first, first.collectionElements != nil {
                hasEdgeArgument = true
            } else if case .implicitMember? = first {
                hasEdgeArgument = true
            } else {
                hasEdgeArgument = false
            }
            if let first, hasEdgeArgument {
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

        // foregroundStyle lives in the generated tier (arities 1-3 —
        // palette symbols need the secondary/tertiary layers). Only the
        // deprecated foregroundColor, absent from the swept interfaces,
        // stays handwritten.
        register("foregroundColor") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: "missing style argument") }
            // The deprecated API takes a COLOR — Color.secondary here, not
            // the hierarchical style (that's foregroundStyle's domain).
            if let color = Coerce.colorLike(value) {
                return AnyView(view.foregroundColor(color))
            }
            return AnyView(view.foregroundStyle(try Coerce.shapeStyle(value)))
        }

        register("background") { [unowned self] view, args, ctx in
            if args.isEmpty {
                return AnyView(view.background())
            }
            if let closure = args.firstUnlabeledClosure {
                let views = try ctx.callBuilderClosure(closure, arguments: []).map(Self.anyView)
                let content = views.count == 1 ? views[0] : AnyView(ZStack { Self.indexed(views) })
                return AnyView(view.background(content))
            }
            // `.background(in: shape)` — the style-less form fills with the
            // ambient background style (OrderRow's status icon plate).
            if args.positional(0) == nil, let shapeArg = args.labeled("in") {
                return AnyView(view.background(in: try Coerce.shape(shapeArg)))
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

        modifiers["shadow"] = HostModifier(name: "shadow") { value, args, _ in
            // `.indigo.shadow(.drop(…))` is ShapeStyle.shadow, NOT the view
            // modifier — a ShadowStyle marker argument only compiles against
            // the style overload, so a style-like receiver keeps its
            // styleness for the downstream foregroundStyle funnel (the
            // FoodTruck forecast pillars).
            if case .host(let any)? = args.positional(0),
               let call = any as? ImplicitMemberCall,
               call.name == "drop" || call.name == "inner",
               let base = try? Coerce.shapeStyle(value) {
                let style = try Coerce.shadowStyle(args.positional(0))
                return .native(AnyShapeStyle(base.shadow(style)))
            }
            let view = try Self.anyView(value)
            let radius = try Coerce.cgFloat(args.labeled("radius") ?? .native(4))
            let color = try args.labeled("color").map(Coerce.color) ?? Color.black.opacity(0.33)
            let x = try args.labeled("x").map(Coerce.cgFloat) ?? 0
            let y = try args.labeled("y").map(Coerce.cgFloat) ?? 0
            return .native(AnyView(view.shadow(color: color, radius: radius, x: x, y: y)))
        }

        register("cornerRadius") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".cornerRadius needs a radius") }
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: try Coerce.cgFloat(value))))
        }
        register("clipShape") { view, args, _ in
            guard let value = args.positional(0) else { throw RuntimeError(message: ".clipShape needs a shape") }
            return AnyView(view.clipShape(try Coerce.shape(value)))
        }
        register("containerShape") { view, args, _ in
            guard let raw = args.positional(0) else {
                throw RuntimeError(message: ".containerShape needs a shape")
            }
            // Insettable boxes carry the REAL modifier (captured with the
            // concrete shape — ContainerRelativeShape fills/clips inside
            // then resolve the continuous card corners). Erased shapes
            // stay inert: the erasure lost InsettableShape.
            if case .host(let any) = raw, let box = any as? ShapeBox,
               let apply = box.containerShapeApplier {
                return apply(view)
            }
            return view
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
            let callback = InterpretedHostCallback(
                closure: closure, context: ctx, diagnosticContext: "onAppear")
            return AnyView(view.onAppear { callback.call() })
        }
        register("onDisappear") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            let callback = InterpretedHostCallback(
                closure: closure, context: ctx, diagnosticContext: "onDisappear")
            return AnyView(view.onDisappear { callback.call() })
        }
        register("onTapGesture") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            let callback = InterpretedHostCallback(
                closure: closure, context: ctx, diagnosticContext: "onTapGesture")
            return AnyView(view.onTapGesture { callback.call() })
        }
        register("onSubmit") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            let callback = InterpretedHostCallback(
                closure: closure, context: ctx, diagnosticContext: "onSubmit")
            return AnyView(view.onSubmit { callback.call() })
        }
        register("onChange") { view, args, ctx in
            guard let value = args.labeled("of") else {
                throw RuntimeError(message: ".onChange needs of:")
            }
            guard let closure = args.firstUnlabeledClosure else { return view }
            let identity = value.stringified
            let initial = args.labeled("initial")?.boolValue ?? false
            return AnyView(view.onChange(of: identity, initial: initial) { oldValue, newValue in
                let arguments: [RuntimeValue]
                switch closure.parameters.count {
                case 0: arguments = []
                case 1: arguments = [value]
                default: arguments = [.native(oldValue), .native(newValue)]
                }
                InterpretedHostCallback(
                    closure: closure,
                    context: ctx,
                    diagnosticContext: "onChange"
                ).call(arguments: arguments)
            })
        }
        register("onPreferenceChange") { view, _, _ in
            // PreferenceKey.Value's associated type is erased in source.
            // Keep the subtree alive; geometry-specific preferences are
            // bridged separately where their concrete values are known.
            view
        }
        register("onOpenURL") { view, args, ctx in
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.onOpenURL { url in
                InterpretedHostCallback(
                    closure: closure,
                    context: ctx,
                    diagnosticContext: "onOpenURL"
                ).call(arguments: [.native(url)])
            })
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
        // Toolbar chrome doesn't paint inside a borderless captured window
        // (the twin's captures show none either) — the view passes through;
        // toolbar ACTIONS become R3 surface, not R2 pixels.
        register("toolbar") { view, _, _ in view }
        register("tableStyle") { view, args, _ in
            switch args.positional(0) {
            case .implicitMember("inset"): return AnyView(view.tableStyle(.inset))
            case .implicitMember("bordered"):
#if canImport(AppKit)
                return AnyView(view.tableStyle(.bordered))
#else
                return AnyView(view.tableStyle(.automatic))
#endif
            default: return AnyView(view.tableStyle(.automatic))
            }
        }
        register("toolbarRole") { view, _, _ in view }
        register("onReceive") { view, args, ctx in
            guard case .host(let any)? = args.positional(0), let box = any as? TimerPublisherBox else {
                throw RuntimeError(message: ".onReceive supports Timer publishers (Timer.publish(...).autoconnect())")
            }
            guard let closure = args.firstUnlabeledClosure else { return view }
            return AnyView(view.onReceive(box.publisher) { date in
                InterpretedHostCallback(
                    closure: closure,
                    context: ctx,
                    diagnosticContext: "onReceive"
                ).call(arguments: [.native(date)])
            })
        }

        // MARK: Container configuration

        register("navigationTitle") { view, args, _ in
            AnyView(view.navigationTitle(args.positional(0)?.stringValue ?? ""))
        }
        register("navigationDestination") { view, _, _ in
            // The destination's interpreted data type cannot satisfy
            // SwiftUI's static Hashable generic at the gateway boundary.
            // Keep the current navigation content intact; trace mode still
            // deep-renders the deferred destination for coverage.
            view
        }

        // ChartContent and ChartProxy have static associated types that are
        // unavailable after interpretation. Preserve the chart surface and
        // accept its presentation/configuration modifiers inertly.
        for name in [
            "chartLegend", "chartOverlay", "chartPlotStyle",
            "chartXAxis", "chartYAxis", "chartYScale",
        ] {
            register(name) { view, _, _ in view }
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
#if canImport(AppKit)
                    if #available(macOS 15.0, *) {
                        return AnyView(view.tabViewStyle(.grouped))
                    }
#endif
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
                    set: { presented in
                        guard !presented else { return }
                        if case .optional(let optional) = stub.box.value {
                            stub.box.value = .none(
                                wrappedTypeName: optional.wrappedTypeName,
                                isImplicitlyUnwrapped: optional.isImplicitlyUnwrapped)
                        } else if let annotation = stub.box.declaredTypeName {
                            stub.box.value = .none(forTypeAnnotation: annotation)
                        } else {
                            stub.box.value = .nilValue
                        }
                    }
                )
                return AnyView(view.sheet(isPresented: isPresented) {
                    if let itemValue = stub.box.value.unwrappedOptionalOrSelf,
                       let views = try? ctx.callBuilderClosure(
                        closure, arguments: [itemValue]).map(Self.anyView) {
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
            case "bordered":
#if canImport(AppKit)
                return AnyView(view.listStyle(.bordered))
#else
                return AnyView(view.listStyle(.automatic))
#endif
            default: return AnyView(view.listStyle(.automatic))
            }
        }
        register("labelStyle") { view, args, ctx in
            guard let styleArg = args.positional(0) else { return view }
            // Custom conformers (`.labelStyle(.cardNavigationHeader)` via an
            // extension static, or a direct `MyStyle()` instance) run their
            // interpreted makeBody through a REAL LabelStyle.
            @MainActor func interpretedStyle(_ value: RuntimeValue) -> InterpretedLabelStyle? {
                guard let interpreter = ctx as? Interpreter else { return nil }
                var resolved = value
                if case .implicitMember = value {
                    resolved = interpreter.resolveForBridge(value, typeName: "LabelStyle")
                }
                guard case .instance(let instance) = resolved,
                      instance.symbol.conformances.contains("LabelStyle"),
                      instance.symbol.methods["makeBody"] != nil else { return nil }
                return InterpretedLabelStyle(instance: instance, interpreter: interpreter)
            }
            if case .implicitMember(let name) = styleArg {
                switch name {
                case "iconOnly": return AnyView(view.labelStyle(.iconOnly))
                case "titleOnly": return AnyView(view.labelStyle(.titleOnly))
                case "titleAndIcon": return AnyView(view.labelStyle(.titleAndIcon))
                case "automatic": return AnyView(view.labelStyle(.automatic))
                default:
                    if let style = interpretedStyle(styleArg) {
                        return AnyView(view.labelStyle(style))
                    }
                    return view
                }
            }
            if let style = interpretedStyle(styleArg) {
                return AnyView(view.labelStyle(style))
            }
            return view
        }

        register("buttonStyle") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "bordered": return AnyView(view.buttonStyle(.bordered))
            case "borderedProminent": return AnyView(view.buttonStyle(.borderedProminent))
            case "plain": return AnyView(view.buttonStyle(.plain))
            case "borderless": return AnyView(view.buttonStyle(.borderless))
            case "link":
#if canImport(AppKit)
                return AnyView(view.buttonStyle(.link))
#else
                return AnyView(view.buttonStyle(.plain))
#endif
            default: return AnyView(view.buttonStyle(.automatic))
            }
        }
        register("pickerStyle") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "segmented": return AnyView(view.pickerStyle(.segmented))
            case "menu": return AnyView(view.pickerStyle(.menu))
            case "inline": return AnyView(view.pickerStyle(.inline))
            case "radioGroup":
#if canImport(AppKit)
                return AnyView(view.pickerStyle(.radioGroup))
#else
                return AnyView(view.pickerStyle(.automatic))
#endif
            default: return AnyView(view.pickerStyle(.automatic))
            }
        }
        register("textFieldStyle") { view, args, _ in
            guard case .implicitMember(let name)? = args.positional(0) else { return view }
            switch name {
            case "roundedBorder": return AnyView(view.textFieldStyle(.roundedBorder))
            case "plain": return AnyView(view.textFieldStyle(.plain))
            case "squareBorder":
#if canImport(AppKit)
                return AnyView(view.textFieldStyle(.squareBorder))
#else
                return AnyView(view.textFieldStyle(.roundedBorder))
#endif
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
        modifiers["strokeBorder"] = HostModifier(name: "strokeBorder") { value, args, _ in
            // InsettableShape's inside-stroke, drawn as a centered stroke on
            // the erased shape — a documented ≤lineWidth/2 divergence
            // (FoodTruck's tile outlines use lineWidth 0.5: sub-antialiasing).
            var shapeBox: ShapeBox?
            if case .host(let any) = value { shapeBox = any as? ShapeBox ?? (any as? PathDrawStub).map { ShapeBox($0.path) } }
            guard let box = shapeBox else {
                throw RuntimeError(message: ".strokeBorder applies to insettable shapes")
            }
            let style = try Coerce.shapeStyle(args.positional(0) ?? .implicitMember("primary"))
            let lineWidth = try args.labeled("lineWidth").map(Coerce.cgFloat) ?? 1
            if let painter = box.strokeBorderPainter {
                return .native(painter(style, lineWidth))
            }
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
