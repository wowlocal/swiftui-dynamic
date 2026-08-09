import SwiftUI
import SwiftInterpreter

/// Keeps a runtime `ShapeStyle` existential reopenable at later generic
/// SwiftUI boundaries. BridgeGen can derive `Style: ShapeStyle` from an
/// interface, but evaluation necessarily stores the value behind `Any`.
/// Opening the existential only when the native generic call is made preserves
/// its concrete rendering semantics without knowing the style's identity.
struct GeneratedShapeStyleCarrier {
    private let style: any ShapeStyle

    init?(_ value: Any) {
        guard let style = value as? any ShapeStyle else { return nil }
        self.style = style
    }

    @MainActor
    func fill<S: Shape>(
        _ shape: S,
        opacity: Double
    ) -> AnyView {
        Self.fill(shape, with: style, opacity: opacity)
    }

    @MainActor
    private static func fill<S: Shape, Style: ShapeStyle>(
        _ shape: S,
        with style: Style,
        opacity: Double
    ) -> AnyView {
        AnyView(shape.fill(style.opacity(opacity)))
    }
}

/// Runtime half of computed `Binding` construction. Swift supplies the generic
/// `Value` from the consuming parameter for contextual `.init(get:set:)`;
/// that inference is not encoded in the runtime value. Binding identity and
/// closure-backed reads/writes are SwiftUI magic, so explicit and contextual
/// spellings share this one semantic primitive instead of teaching each
/// control how to recognize initializer syntax.
enum BindingSemanticBridge {
    static func makeStub(
        arguments: CallArguments,
        context: EvalContext,
        valueType: String? = nil
    ) throws -> BindingStub {
        let get = arguments.closure(labeled: "get")
            ?? arguments.firstUnlabeledClosure
        let set = arguments.closure(labeled: "set")
        let valueType = valueType
            ?? arguments.labeled("__genericArguments")?.stringValue
        let resolved: (RuntimeValue) -> RuntimeValue = { value in
            guard let valueType,
                  let interpreter = context as? Interpreter else {
                return value
            }
            return interpreter.resolveForBridge(value, typeName: valueType)
        }
        let initial = try get.map {
            resolved(try context.callClosure($0, arguments: []))
        } ?? .void
        let box = Box(initial)
        if let set {
            let callback = InterpretedHostCallback(
                closure: set,
                context: context,
                diagnosticContext: "Binding.set")
            box.onChange = {
                callback.call(arguments: [resolved(box.value)])
            }
        }
        return BindingStub(box: box)
    }

    static func contextualStub(
        from value: RuntimeValue,
        context: EvalContext
    ) throws -> BindingStub? {
        guard case .host(let payload) = value,
              let call = payload as? ImplicitMemberCall,
              call.name == "init",
              (call.arguments.closure(labeled: "get")
                ?? call.arguments.firstUnlabeledClosure) != nil,
              call.arguments.closure(labeled: "set") != nil else {
            return nil
        }
        return try makeStub(arguments: call.arguments, context: context)
    }
}

/// Resolves `.implicitMember` values (`.red`, `.title`, `.leading`) against
/// the SwiftUI type a gateway parameter expects — the "expected type context"
/// trick reduced to lookup tables, dodging real type inference.
enum Coerce {
    /// Apply an existing concrete coercion to one Optional layer. SDK
    /// gateways share this boundary so a source `nil` remains native nil
    /// instead of being diagnosed by the wrapped type's coercer.
    static func optional<T>(
        _ value: RuntimeValue,
        coercing coerce: (RuntimeValue) throws -> T
    ) throws -> T? {
        if value.isNil { return nil }
        if case .optional(let optional) = value,
           let wrapped = optional.wrapped {
            return try coerce(wrapped)
        }
        return try coerce(value)
    }

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

    static func bindingBox(
        _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Box {
        if case .host(let any) = value, let stub = any as? BindingStub { return stub.box }
        if let context,
           let stub = try BindingSemanticBridge.contextualStub(
                from: value, context: context) {
            return stub.box
        }
        // `.constant(x)` — a binding to a fixed value (writes go nowhere).
        if case .host(let any) = value, let call = any as? ImplicitMemberCall,
           call.name == "constant" {
            return Box(call.arguments.positional(0) ?? .void)
        }
        throw RuntimeError(message: "expected a binding like $someState, got \(value.stringified)")
    }

    static func boolBinding(
        _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Binding<Bool> {
        let box = try bindingBox(value, context: context)
        return Binding(
            get: { box.value.boolValue ?? false },
            set: { box.value = .native($0) }
        )
    }

    /// A binding over the interpreted Hashable carrier, for the interface
    /// generics that constrain their value to `Hashable` alone
    /// (`FocusState<Value>` where `Value == T?`). Nil round-trips as the
    /// interpreter's own nil rather than as a carrier wrapping `.void`, so
    /// "nothing is focused" stays distinguishable from "a value that is
    /// absent".
    static func hashableOptionalBinding(
        _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Binding<InterpretedHashableValue?> {
        let box = try bindingBox(value, context: context)
        return Binding(
            get: {
                // An unfocused `@FocusState var x: Foo?` reads as the
                // interpreter's nil, or as `.void` while it is still
                // uninitialized; both mean "nothing is focused".
                if box.value.isNil { return nil }
                if case .void = box.value { return nil }
                return InterpretedHashableValue(runtimeValue: box.value)
            },
            set: { box.value = $0?.runtimeValue ?? .nilValue }
        )
    }

    /// Tagged-selection binding: reads the state's stable string identity
    /// and writes back the ORIGINAL runtime value a `.tag(...)` registered
    /// for it — enum-case selections keep switch-matching after a control
    /// drives the binding.
    static func selectionBinding(
        _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Binding<String> {
        let box = try bindingBox(value, context: context)
        return Binding(
            get: { NavigationSelectionValues.identity(box.value) },
            set: { newTag in
                box.value = NavigationSelectionValues.byTag[newTag] ?? .native(newTag)
            }
        )
    }

    static func stringBinding(
        _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Binding<String> {
        let box = try bindingBox(value, context: context)
        return Binding(
            get: { box.value.stringValue ?? "" },
            set: { box.value = .native($0) }
        )
    }

    /// If the underlying state is an Int, writes round back to Int so the
    /// interpreted program keeps seeing the type it declared.
    static func doubleBinding(
        _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Binding<Double> {
        let box = try bindingBox(value, context: context)
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
        if let color = colorLike(value) { return color }
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected a color like .blue, got \(value.stringified)")
        }
        throw RuntimeError(message: "unknown color '.\(name)'")
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
    /// `.continuous` corners are squircles — dropping the style renders
    /// circular arcs and diffs as L-brackets at every corner (the
    /// FoodTruck card chrome).
    static func roundedCornerStyle(_ value: RuntimeValue?) -> RoundedCornerStyle {
        if case .implicitMember("continuous")? = value { return .continuous }
        return .circular
    }

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

    /// `.drop(color:radius:x:y:)` / `.inner(...)` — ShadowStyle factories
    /// (defaults mirror SwiftUI's declared signatures: drop shadows read
    /// opacity 0.33, inner 0.55 — SwiftUICore.swiftinterface).
    static func shadowStyle(_ value: RuntimeValue?) throws -> ShadowStyle {
        guard case .host(let any)? = value, let call = any as? ImplicitMemberCall,
              call.name == "drop" || call.name == "inner" else {
            throw RuntimeError(message: "expected a .drop(…)/.inner(…) shadow style")
        }
        let color = call.arguments.labeled("color").flatMap(colorLike)
            ?? Color(.sRGBLinear, white: 0, opacity: call.name == "drop" ? 0.33 : 0.55)
        let radius = call.arguments.labeled("radius").flatMap { try? cgFloat($0) } ?? 0
        let x = call.arguments.labeled("x").flatMap { try? cgFloat($0) } ?? 0
        let y = call.arguments.labeled("y").flatMap { try? cgFloat($0) } ?? 0
        return call.name == "drop"
            ? .drop(color: color, radius: radius, x: x, y: y)
            : .inner(color: color, radius: radius, x: x, y: y)
    }

    private static func eraseShapeStyle<S: ShapeStyle>(
        _ value: S
    ) -> AnyShapeStyle {
        AnyShapeStyle(value)
    }

    private static func opacityShapeStyle<S: ShapeStyle>(
        _ value: S, amount: Double
    ) -> any ShapeStyle {
        value.opacity(amount)
    }

    private static func shadowShapeStyle<S: ShapeStyle>(
        _ value: S, style: ShadowStyle
    ) -> any ShapeStyle {
        value.shadow(style)
    }

    /// The wide funnel for protocol-constrained ShapeStyle positions. Return
    /// the concrete style existential so generated generic calls can reopen
    /// it; erasing here changes SwiftUI rendering even when the visual value
    /// appears equivalent.
    static func genericShapeStyle(
        _ value: RuntimeValue, context: EvalContext? = nil
    ) throws -> any ShapeStyle {
        if let context,
           let generated = GeneratedSDKProtocolValueCoercions.coerceShapeStyle(
            value, context: context) {
            return generated
        }
        if case .host(let any) = value {
            if let style = any as? AnyShapeStyle { return style }
            if let color = any as? Color { return color }
            if let gradient = any as? LinearGradient { return gradient }
            if let gradient = any as? AnyGradient { return gradient }
            if let gradient = any as? RadialGradient { return gradient }
            if let gradient = any as? AngularGradient { return gradient }
            if let chained = any as? ChainedImplicitCall {
                switch chained.member {
                case "opacity":
                    let amount = try double(chained.arguments.positional(0) ?? .native(1.0))
                    if let base = colorLike(chained.base) {
                        return base.opacity(amount)
                    }
                    // Hierarchical/material bases keep their REAL style
                    // through the chain (`.quaternary.opacity(0.5)` — the
                    // FoodTruck card-tile fill; a flat-gray stand-in reads
                    // 12/255 darker than the compiled render).
                    return opacityShapeStyle(
                        try genericShapeStyle(
                            chained.base, context: context),
                        amount: amount)
                case "gradient":
                    guard let base = colorLike(chained.base) else {
                        throw RuntimeError(message: "unknown color before '.gradient' in style chain")
                    }
                    return base.gradient
                case "shadow":
                    // `.indigo.shadow(.drop(color:radius:x:))` — the
                    // FoodTruck forecast pillar. The chain keeps its REAL
                    // base style.
                    let style = try shadowStyle(chained.arguments.positional(0))
                    return shadowShapeStyle(
                        try genericShapeStyle(
                            chained.base, context: context),
                        style: style)
                default:
                    throw RuntimeError(message: "unsupported style '.\(chained.baseName ?? "…").\(chained.member)'")
                }
            }
        }
        if case .host(let any) = value, let call = any as? ImplicitMemberCall {
            // A zero-argument marker CALL is the marker itself — chain bases
            // arrive in this carrier (`.indigo` under `.shadow(…)`).
            if call.arguments.arguments.isEmpty {
                return try genericShapeStyle(
                    .implicitMember(call.name), context: context)
            }
            // `.linearGradient(colors:startPoint:endPoint:)` — the factory
            // spelling of the gradient styles (FoodTruck's forecast fill).
            if call.name == "linearGradient" {
                let colors = (call.arguments.labeled("colors")?.arrayValue ?? [])
                    .compactMap(colorLike)
                let start = call.arguments.labeled("startPoint")
                    .flatMap { try? unitPoint($0) } ?? .top
                let end = call.arguments.labeled("endPoint")
                    .flatMap { try? unitPoint($0) } ?? .bottom
                if !colors.isEmpty {
                    return LinearGradient(
                        colors: colors, startPoint: start, endPoint: end)
                }
            }
        }
        if case .implicitMember(let name) = value {
            switch name {
            // In a STYLE position the hierarchy names are HIERARCHICAL
            // styles deriving from the current primary (the accent-tinted
            // card-header icons) — Color.primary/.secondary are only for
            // COLOR positions (Coerce.color).
            case "primary": return HierarchicalShapeStyle.primary
            case "secondary": return HierarchicalShapeStyle.secondary
            case "tertiary": return HierarchicalShapeStyle.tertiary
            case "quaternary": return HierarchicalShapeStyle.quaternary
            case "ultraThinMaterial": return Material.ultraThin
            case "thinMaterial": return Material.thin
            case "regularMaterial": return Material.regular
            case "thickMaterial": return Material.thick
            case "ultraThickMaterial": return Material.ultraThick
            case "bar": return Material.bar
            default: break
            }
            if let color = colorNamed(name) { return color }
        }
        throw RuntimeError(message: "expected a color/gradient/material, got \(value.stringified)")
    }

    /// Direct AnyShapeStyle parameters intentionally erase at their declared
    /// boundary; generic ShapeStyle parameters use `genericShapeStyle` above.
    static func shapeStyle(
        _ value: RuntimeValue, context: EvalContext? = nil
    ) throws -> AnyShapeStyle {
        eraseShapeStyle(try genericShapeStyle(value, context: context))
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
        if let elements = value.collectionElements {
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
        if case .host(let any) = value, let real = any as? UnitPoint {
            return real
        }
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

    /// `Gradient.Stop(color:location:)` / `.init(color:location:)` — the
    /// dynamic element of every `stops:` gradient form.
    static func gradientStop(_ value: RuntimeValue) throws -> Gradient.Stop {
        if case .host(let any) = value, let stop = any as? Gradient.Stop {
            return stop
        }
        if case .host(let any) = value, let call = any as? ImplicitMemberCall,
           let colorArg = call.arguments.labeled("color"),
           let locationArg = call.arguments.labeled("location") {
            return Gradient.Stop(
                color: try color(colorArg),
                location: try cgFloat(locationArg))
        }
        throw RuntimeError(message: "expected a Gradient.Stop like .init(color:location:), got \(value.stringified)")
    }

    static func gradientStops(_ value: RuntimeValue) throws -> [Gradient.Stop] {
        guard let array = value.arrayValue else {
            throw RuntimeError(message: "expected an array of Gradient.Stop values")
        }
        return try array.map(gradientStop)
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

    static func shape(
        _ value: RuntimeValue, context: EvalContext? = nil
    ) throws -> AnyShape {
        if let context,
           let generated = GeneratedSDKProtocolValueCoercions.coerceShape(
            value, context: context) {
            return generated
        }
        if case .host(let any) = value,
           let box = ShapeBox.opening(any) {
            return box.shape
        }
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
            return AnyShape(RoundedRectangle(
                cornerRadius: radius,
                style: roundedCornerStyle(call.arguments.labeled("style"))))
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
