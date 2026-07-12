import SwiftUI
import SwiftInterpreter

/// Final host conversions for generated gateways. SwiftUI modifiers and
/// constructors still use ParamSpec for local selection; generated Foundation
/// methods/properties carry parsed HostFunction/HostProperty contracts and use
/// ParamTag only after a method overload has been selected. Hand-written
/// gateways are consulted first and always win.
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
    case decimal, characterSet, indexSet, dateComponents, dateInterval
    case indexPath, intArray, intRange
    case calendarComponent, calendarComponentSet
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
        case .decimal:
            // Decimal is ExpressibleByInteger/FloatLiteral — int and double
            // arguments are legal native call shapes, not coercion cheats.
            if let d: Decimal = hostValue(value) { return d }
            if case .int(let i) = value { return Decimal(i) }
            if let d = value.doubleValue { return Decimal(d) }
            throw RuntimeError(message: "expected a Decimal")
        case .characterSet:
            guard let set: CharacterSet = hostValue(value) else { throw RuntimeError(message: "expected a CharacterSet") }
            return set
        case .indexSet:
            guard let set: IndexSet = hostValue(value) else { throw RuntimeError(message: "expected an IndexSet") }
            return set
        case .dateComponents:
            guard let components: DateComponents = hostValue(value) else { throw RuntimeError(message: "expected DateComponents") }
            return components
        case .dateInterval:
            guard let interval: DateInterval = hostValue(value) else { throw RuntimeError(message: "expected a DateInterval") }
            return interval
        case .indexPath:
            guard let path: IndexPath = hostValue(value) else { throw RuntimeError(message: "expected an IndexPath") }
            return path
        case .intArray:
            guard let array = value.arrayValue else { throw RuntimeError(message: "expected [Int]") }
            return try array.map { element -> Int in
                guard let i = element.intValue else { throw RuntimeError(message: "expected [Int]") }
                return i
            }
        case .intRange:
            // Interpreted `2..<5` lives as RuntimeRangeValue; closed ranges
            // are legal native call shapes via RangeExpression.
            if let runtime = value.rangeValue {
                if let range = runtime.halfOpenIntRange { return range }
                if let closed = runtime.closedIntRange { return closed.lowerBound..<(closed.upperBound + 1) }
            }
            if let range: Range<Int> = hostValue(value) { return range }
            if let closed: ClosedRange<Int> = hostValue(value) { return closed.lowerBound..<(closed.upperBound + 1) }
            throw RuntimeError(message: "expected a Range<Int>")
        case .calendarComponent:
            return try Coerce.calendarComponent(value)
        case .calendarComponentSet:
            // Native code writes `[.year, .month]` — Set's array-literal
            // conformance; the interpreted array coerces element-wise.
            guard let array = value.collectionElements else {
                throw RuntimeError(message: "expected a set of calendar components")
            }
            return Set(try array.map(Coerce.calendarComponent))
        }
    }

    /// Host-typed argument extraction: the raw payload, or the wrapped value
    /// when a hand box (GeneratedMemberCarrier) is standing in for it.
    private static func hostValue<T>(_ value: RuntimeValue) -> T? {
        if let direct = value.hostPayload as? T { return direct }
        if let carrier = value.hostPayload as? GeneratedMemberCarrier,
           let unwrapped = carrier.generatedMemberValue as? T {
            return unwrapped
        }
        return nil
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

/// One overload of a generated instance method. Its parsed declaration owns
/// call validation and overload ranking; ParamTag is now only the final
/// conversion from an already-validated runtime argument to static host code.
struct GeneratedMemberOverload {
    let signature: HostSignature
    let params: [ParamSpec]
    let invoke: (Any, [Any]) throws -> RuntimeValue
}

struct GeneratedMemberSet {
    let overloads: [GeneratedMemberOverload]

    init(_ overloads: [GeneratedMemberOverload]) {
        self.overloads = overloads
    }
}

/// Namespace the generated members file extends with `buildProperties()` /
/// `buildMethods()`. Keys are "TypeName.memberName" against the receiver's
/// logical SDK type, so hand boxes can expose their wrapped value without
/// weakening receiver validation.
enum GeneratedMembers {
    static let properties: [String: HostProperty] = buildProperties()

    static let methods: [String: GeneratedMemberSet] = {
        var grouped: [String: GeneratedMemberSet] = [:]
        for (key, overloads) in buildMethods() {
            grouped[key] = GeneratedMemberSet(overloads)
        }
        return grouped
    }()

    static func registerMethod(
        _ table: inout [String: [GeneratedMemberOverload]],
        _ declaration: String,
        _ params: [ParamSpec],
        _ invoke: @escaping (Any, [Any]) throws -> RuntimeValue
    ) {
        let signature: HostSignature
        do {
            signature = try HostSignature(parsing: declaration)
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid host declaration '\(declaration)': \(error)")
        }
        guard signature.kind == .method, let receiverType = signature.receiverType,
              signature.parameters.count == params.count else {
            preconditionFailure(
                "BridgeGen emitted inconsistent method metadata for '\(declaration)'")
        }
        let key = "\(receiverType).\(signature.name)"
        table[key, default: []].append(GeneratedMemberOverload(
            signature: signature, params: params, invoke: invoke))
    }

    static func registerProperty(
        _ table: inout [String: HostProperty],
        _ declaration: String,
        _ get: @escaping (Any) -> RuntimeValue?
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard signature.kind == .property,
                  let receiverType = signature.receiverType else {
                preconditionFailure(
                    "BridgeGen emitted inconsistent property metadata for '\(declaration)'")
            }
            let property = try HostProperty(
                signature: signature, get: { receiver, _ in
                    guard let rawReceiver = receiver.hostPayload else {
                        throw RuntimeError(
                            message: "generated property '\(declaration)' received no host payload",
                            fatal: true)
                    }
                    let logicalReceiver = (rawReceiver as? GeneratedMemberCarrier)?
                        .generatedMemberValue ?? rawReceiver
                    guard let value = get(logicalReceiver) else {
                        throw RuntimeError(
                            message: "generated property '\(declaration)' receiver downcast failed",
                            fatal: true)
                    }
                    return value
                })
            let key = "\(receiverType).\(signature.name)"
            guard table[key] == nil else {
                preconditionFailure(
                    "BridgeGen emitted duplicate property metadata for '\(declaration)'")
            }
            table[key] = property
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid host property '\(declaration)': \(error)")
        }
    }

    /// The bridgeHostMember hook: hand-written boxes have already refused by
    /// the time this runs; the ObjC trampoline and ad-hoc cases follow it.
    /// A BOX that refused still exposes its wrapped value — the generated
    /// table serves the members the hand box never implemented
    /// (ParityCheck finding: boxes were SHADOWING ~40 generated members).
    /// Runtime type names that differ from the swiftinterface's spelling
    /// (Decimal IS the imported C struct NSDecimal — `type(of:)` prints the
    /// runtime name, the table keys on the Swift one).
    static func keyTypeName(of value: Any) -> String {
        let name = String(describing: type(of: value))
        return name == "NSDecimal" ? "Decimal" : name
    }

    static func member(_ name: String, on value: Any) -> RuntimeValue? {
        method(name, on: value)
    }

    static func property(_ name: String, on value: Any) -> HostProperty? {
        let logicalReceiver = (value as? GeneratedMemberCarrier)?
            .generatedMemberValue ?? value
        let key = "\(keyTypeName(of: logicalReceiver)).\(name)"
        return properties[key]
    }

    /// Methods-only lookup for CALL-site collision rescue: the property
    /// `url.query` already answered the access, but the call shape names
    /// `query(percentEncoded:)` — native overload resolution picks the
    /// method, so the rescue asks this table directly.
    static func method(_ name: String, on value: Any, unwrapCarrier: Bool = true) -> RuntimeValue? {
        if unwrapCarrier, let carrier = value as? GeneratedMemberCarrier,
           let unwrapped = method(name, on: carrier.generatedMemberValue) {
            return unwrapped
        }
        let key = "\(keyTypeName(of: value)).\(name)"
        guard let set = methods[key] else { return nil }
        return .hostFunction(GeneratedDispatch.memberFunction(
            name: name, overloads: set, base: value))
    }
}

extension GeneratedDispatch {
    /// Bind one receiver to the cached generated contracts. Parsing happened
    /// once while the table was built; only lightweight immutable gateway
    /// descriptors are created for a concrete value lookup.
    static func memberFunction(
        name: String, overloads: GeneratedMemberSet, base: Any
    ) -> HostFunction {
        do {
            let functions = try overloads.overloads.map { overload in
                try HostFunction(signature: overload.signature) { args, ctx in
                    guard overload.params.count == args.arguments.count else {
                        throw RuntimeError(message:
                            "generated metadata disagrees with '\(overload.signature.declaration)'")
                    }
                    let values = try zip(overload.params, args.arguments).map {
                        param, argument in
                        try coerce(param.tag, argument.value, ctx)
                    }
                    return try overload.invoke(base, values)
                }
            }
            if functions.count == 1 { return functions[0] }
            return try HostFunction(overloads: functions)
        } catch {
            preconditionFailure(
                "invalid generated overload set for '\(name)': \(error)")
        }
    }

    static func member(
        name: String,
        overloads: GeneratedMemberSet,
        base: Any,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> RuntimeValue {
        try memberFunction(name: name, overloads: overloads, base: base)
            .invoke(args, ctx)
    }
}

/// Wrap a generated member result through the runtime's normalizer. It
/// preserves host Optional wrappers (including nesting) before classifying
/// scalar and framework payloads.
func generatedMemberResult<Wrapped>(_ value: Wrapped?) -> RuntimeValue {
    .native(value)
}

func generatedMemberResult(_ value: Any) -> RuntimeValue {
    .native(value)
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
        if let array = value.collectionElements {
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


/// Hand boxes adopt this so the generated table can serve the members the
/// box itself never implemented (the wrapped value IS the SDK value).
protocol GeneratedMemberCarrier {
    var generatedMemberValue: Any { get }
}
