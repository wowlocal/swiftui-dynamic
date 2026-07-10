import SwiftUI
import SwiftInterpreter

/// The type-directed call boundary for generated gateways: each generated
/// overload declares parameter specs (label + coercible type tag); dispatch
/// filters candidates by label shape and per-argument coercibility, prefers
/// the most specific match, and invokes statically-compiled SwiftUI calls.
/// Hand-written gateways are consulted first and always win.
enum ParamTag: String {
    case string, bool, int, double, cgFloat
    case color, font, fontWeight, angle, animation
    case alignment, horizontalAlignment, verticalAlignment, textAlignment
    case edgeSet, unitPoint, contentMode, imageScale, buttonRole
    case bindingBool, bindingString, bindingDouble
    case shapeStyle, anyView, shape
    case visibility, axisSet, edgeInsets, gradient, gridItems
    case axis, colorArray
    case builder, action, equatable
    // Foundation-value tags for the generated-members tier.
    case date, url, data, stringArray
}

struct ParamSpec {
    let label: String?
    let tag: ParamTag
    let hasDefault: Bool

    init(_ label: String?, _ tag: ParamTag, hasDefault: Bool = false) {
        self.label = label
        self.tag = tag
        self.hasDefault = hasDefault
    }
}

/// Wraps an interpreted action closure so it can round-trip through `[Any]`
/// (function types with isolation annotations don't cast reliably through Any).
/// Only ever invoked on the main actor.
struct ActionValue: @unchecked Sendable {
    let run: @MainActor () -> Void
}

struct GeneratedOverload {
    let params: [ParamSpec]
    let invoke: @MainActor (AnyView, [Any]) throws -> AnyView
}

struct GeneratedConstructor {
    let params: [ParamSpec]
    let invoke: @MainActor ([Any]) throws -> AnyView
}

/// Generated overloads grouped once by the only arity that can match. This
/// replaces sorting and scanning every generated candidate on every call.
struct GeneratedOverloadSet {
    let byArity: [Int: [GeneratedOverload]]
    let count: Int

    init(_ overloads: [GeneratedOverload]) {
        var byArity: [Int: [GeneratedOverload]] = [:]
        for overload in overloads {
            byArity[overload.params.count, default: []].append(overload)
        }
        self.byArity = byArity
        self.count = overloads.count
    }
}

struct GeneratedConstructorSet {
    let byArity: [Int: [GeneratedConstructor]]
    let count: Int

    init(_ overloads: [GeneratedConstructor]) {
        var byArity: [Int: [GeneratedConstructor]] = [:]
        for overload in overloads {
            byArity[overload.params.count, default: []].append(overload)
        }
        self.byArity = byArity
        self.count = overloads.count
    }
}

enum GeneratedDispatch {
    static func coerce(_ tag: ParamTag, _ value: RuntimeValue, _ ctx: EvalContext) throws -> Any {
        switch tag {
        case .string:
            guard let s = value.stringValue else { throw RuntimeError(message: "expected a String") }
            return s
        case .bool:
            guard let b = value.boolValue else { throw RuntimeError(message: "expected a Bool") }
            return b
        case .int:
            guard let i = value.intValue else { throw RuntimeError(message: "expected an Int") }
            return i
        case .double:
            return try Coerce.double(value)
        case .cgFloat:
            return try Coerce.cgFloat(value)
        case .color:
            return try Coerce.color(value)
        case .font:
            return try Coerce.font(value)
        case .fontWeight:
            return try Coerce.fontWeight(value)
        case .angle:
            return try Coerce.angle(value)
        case .animation:
            return try Coerce.animation(value)
        case .alignment:
            return try Coerce.alignment(value)
        case .horizontalAlignment:
            return try Coerce.horizontalAlignment(value)
        case .verticalAlignment:
            return try Coerce.verticalAlignment(value)
        case .textAlignment:
            return try Coerce.textAlignment(value)
        case .edgeSet:
            return try Coerce.edgeSet(value)
        case .unitPoint:
            return try Coerce.unitPoint(value)
        case .contentMode:
            return try Coerce.contentMode(value)
        case .imageScale:
            return try Coerce.imageScale(value)
        case .buttonRole:
            guard let role = try Coerce.buttonRole(value) else {
                throw RuntimeError(message: "expected a button role")
            }
            return role
        case .axis:
            return try Coerce.axis(value)
        case .colorArray:
            guard let array = value.arrayValue else { throw RuntimeError(message: "expected [Color]") }
            return try array.map(Coerce.color)
        case .bindingBool:
            return try Coerce.boolBinding(value)
        case .bindingString:
            return try Coerce.stringBinding(value)
        case .bindingDouble:
            return try Coerce.doubleBinding(value)
        case .shapeStyle:
            return try Coerce.shapeStyle(value)
        case .anyView:
            return try ViewRegistry.anyView(value)
        case .shape:
            return try Coerce.shape(value)
        case .visibility:
            return try Coerce.visibility(value)
        case .axisSet:
            return try Coerce.axisSet(value)
        case .edgeInsets:
            return try Coerce.edgeInsets(value)
        case .gradient:
            return try Coerce.gradient(value)
        case .gridItems:
            return try Coerce.gridItems(value)
        case .builder:
            guard let closure = value.closureValue else { throw RuntimeError(message: "expected a view closure") }
            let views = try ctx.callBuilderClosure(closure, arguments: []).map(ViewRegistry.anyView)
            return views.count == 1 ? views[0] : AnyView(VStack { ViewRegistry.indexed(views) })
        case .action:
            guard let closure = value.closureValue else { throw RuntimeError(message: "expected a closure") }
            return ActionValue(run: { _ = try? ctx.callClosure(closure, arguments: []) })
        case .equatable:
            return value.stringified
        case .date:
            guard let date = value.hostPayload as? Date else { throw RuntimeError(message: "expected a Date") }
            return date
        case .url:
            guard let url = value.hostPayload as? URL else { throw RuntimeError(message: "expected a URL") }
            return url
        case .data:
            guard let data = value.hostPayload as? Data else { throw RuntimeError(message: "expected Data") }
            return data
        case .stringArray:
            guard let array = value.arrayValue else { throw RuntimeError(message: "expected [String]") }
            return try array.map { element -> String in
                guard let s = element.stringValue else { throw RuntimeError(message: "expected [String]") }
                return s
            }
        }
    }

    private static func matches(_ params: [ParamSpec], _ args: CallArguments, _ ctx: EvalContext) -> [Any]? {
        guard params.count == args.arguments.count else { return nil }
        var values: [Any] = []
        for (param, argument) in zip(params, args.arguments) {
            let isClosureParam = param.tag == .builder || param.tag == .action
            let labelOK = argument.label == param.label
                || (argument.isTrailing && argument.label == nil && isClosureParam)
            guard labelOK, let coerced = try? coerce(param.tag, argument.value, ctx) else { return nil }
            values.append(coerced)
        }
        return values
    }

    static func dispatch(
        name: String,
        overloads: GeneratedOverloadSet,
        view: AnyView,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> AnyView {
        for overload in overloads.byArity[args.arguments.count] ?? [] {
            guard let values = matches(overload.params, args, ctx) else { continue }
            return try overload.invoke(view, values)
        }
        let shape = args.arguments.map { $0.label ?? "_" }.joined(separator: ":")
        throw RuntimeError(message: "no matching overload for .\(name)(\(shape):) — argument types or labels don't fit")
    }

    static func construct(
        name: String,
        overloads: GeneratedConstructorSet,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> AnyView {
        for overload in overloads.byArity[args.arguments.count] ?? [] {
            guard let values = matches(overload.params, args, ctx) else { continue }
            return try overload.invoke(values)
        }
        let shape = args.arguments.map { $0.label ?? "_" }.joined(separator: ":")
        throw RuntimeError(message: "no matching initializer for \(name)(\(shape):) — argument types or labels don't fit")
    }
}

// MARK: - Generated members (Foundation value types)

/// One overload of a generated instance method: receiver arrives as the raw
/// host `Any`, arguments pre-coerced by ParamTag.
struct GeneratedMemberOverload {
    let params: [ParamSpec]
    let invoke: (Any, [Any]) throws -> RuntimeValue
}

struct GeneratedMemberSet {
    let byArity: [Int: [GeneratedMemberOverload]]

    init(_ overloads: [GeneratedMemberOverload]) {
        var byArity: [Int: [GeneratedMemberOverload]] = [:]
        for overload in overloads {
            byArity[overload.params.count, default: []].append(overload)
        }
        self.byArity = byArity
    }
}

/// Namespace the generated members file extends with `buildProperties()` /
/// `buildMethods()`. Keys are "TypeName.memberName" against the receiver's
/// dynamic type, so a failed downcast (name collision with a non-SDK type)
/// falls through to the next dispatch tier instead of erroring.
enum GeneratedMembers {
    static let properties: [String: (Any) -> RuntimeValue?] = buildProperties()

    static let methods: [String: GeneratedMemberSet] = {
        var grouped: [String: GeneratedMemberSet] = [:]
        for (key, overloads) in buildMethods() {
            grouped[key] = GeneratedMemberSet(overloads)
        }
        return grouped
    }()

    static func registerMethod(
        _ table: inout [String: [GeneratedMemberOverload]],
        _ key: String,
        _ params: [ParamSpec],
        _ invoke: @escaping (Any, [Any]) throws -> RuntimeValue
    ) {
        table[key, default: []].append(GeneratedMemberOverload(params: params, invoke: invoke))
    }

    /// The bridgeHostMember hook: hand-written boxes have already refused by
    /// the time this runs; the ObjC trampoline and ad-hoc cases follow it.
    static func member(_ name: String, on value: Any) -> RuntimeValue? {
        let key = "\(type(of: value)).\(name)"
        if let getter = properties[key] {
            return getter(value)
        }
        if let set = methods[key] {
            return .hostFunction(HostFunction(name: name) { args, ctx in
                try GeneratedDispatch.member(name: name, overloads: set, base: value, args: args, ctx: ctx)
            })
        }
        return nil
    }
}

extension GeneratedDispatch {
    static func member(
        name: String,
        overloads: GeneratedMemberSet,
        base: Any,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> RuntimeValue {
        for overload in overloads.byArity[args.arguments.count] ?? [] {
            guard let values = matches(overload.params, args, ctx) else { continue }
            return try overload.invoke(base, values)
        }
        // A shape the sweep couldn't map (blocked param type, unemitted
        // overload) absorbs like the trampoline does — never dies mid-render.
        if LiveCheckSupport.traceLifecycle {
            let shapes = args.arguments
                .map { "\($0.label ?? "_"): \($0.value.stringified.prefix(220))" }
                .joined(separator: ", ")
            print("   ⚠ generated .\(name) on \(type(of: base)): no overload for (\(shapes))")
        }
        return .native(ChainedImplicitCall(base: .native(base), member: name, arguments: args))
    }
}

/// Wraps a generated member's result: Optionals flatten (nil → .nilValue),
/// everything else hosts through the normalizing `.native` constructors.
func generatedMemberResult(_ value: Any) -> RuntimeValue {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let child = mirror.children.first else { return .nilValue }
        return generatedMemberResult(child.value)
    }
    return .native(value)
}

/// Namespace the generated file extends with `build()`.
enum GeneratedModifiers {
    static let table: [String: GeneratedOverloadSet] = {
        var grouped: [String: GeneratedOverloadSet] = [:]
        for (name, overloads) in build() {
            grouped[name] = GeneratedOverloadSet(overloads)
        }
        return grouped
    }()

    static func register(
        _ table: inout [String: [GeneratedOverload]],
        _ name: String,
        _ params: [ParamSpec],
        _ invoke: @escaping @MainActor (AnyView, [Any]) throws -> AnyView
    ) {
        table[name, default: []].append(GeneratedOverload(params: params, invoke: invoke))
    }
}

/// Namespace the generated constructors file extends with `build()`.
enum GeneratedConstructors {
    static let table: [String: GeneratedConstructorSet] = {
        var grouped: [String: GeneratedConstructorSet] = [:]
        for (name, overloads) in build() {
            grouped[name] = GeneratedConstructorSet(overloads)
        }
        return grouped
    }()

    static func register(
        _ table: inout [String: [GeneratedConstructor]],
        _ name: String,
        _ params: [ParamSpec],
        _ invoke: @escaping @MainActor ([Any]) throws -> AnyView
    ) {
        table[name, default: []].append(GeneratedConstructor(params: params, invoke: invoke))
    }
}

/// Bridges an ActionValue (from `[Any]`) into the plain `() -> Void` shape
/// framework APIs take; safe because SwiftUI invokes these on the main thread.
nonisolated func generatedAction(_ value: Any) -> () -> Void {
    let action = value as! ActionValue
    return { MainActor.assumeIsolated { action.run() } }
}

// MARK: - Coercions added for generated surface

extension Coerce {
    static func buttonRole(_ value: RuntimeValue) throws -> ButtonRole? {
        if value.isNil { return nil }
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected a button role like .destructive")
        }
        switch name {
        case "destructive": return .destructive
        case "cancel": return .cancel
        default: throw RuntimeError(message: "unknown button role '.\(name)'")
        }
    }

    static func axis(_ value: RuntimeValue) throws -> Axis {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected .horizontal or .vertical")
        }
        switch name {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        default: throw RuntimeError(message: "unknown axis '.\(name)'")
        }
    }

    static func visibility(_ value: RuntimeValue) throws -> Visibility {
        guard case .implicitMember(let name) = value else {
            throw RuntimeError(message: "expected .visible/.hidden/.automatic")
        }
        switch name {
        case "visible": return .visible
        case "hidden": return .hidden
        case "automatic": return .automatic
        default: throw RuntimeError(message: "unknown visibility '.\(name)'")
        }
    }

    static func axisSet(_ value: RuntimeValue) throws -> Axis.Set {
        if case .implicitMember(let name) = value {
            switch name {
            case "horizontal": return .horizontal
            case "vertical": return .vertical
            default: throw RuntimeError(message: "unknown axis '.\(name)'")
            }
        }
        if let array = value.arrayValue {
            var set: Axis.Set = []
            for element in array { set.insert(try axisSet(element)) }
            return set
        }
        throw RuntimeError(message: "expected .horizontal/.vertical")
    }

    static func edgeInsets(_ value: RuntimeValue) throws -> EdgeInsets {
        if case .host(let any) = value, let insets = any as? EdgeInsets { return insets }
        throw RuntimeError(message: "expected EdgeInsets(top:leading:bottom:trailing:)")
    }

    static func gradient(_ value: RuntimeValue) throws -> Gradient {
        if case .host(let any) = value, let gradient = any as? Gradient { return gradient }
        if let array = value.arrayValue {
            return Gradient(colors: try array.map(color))
        }
        throw RuntimeError(message: "expected Gradient(colors:) or [Color]")
    }
}
