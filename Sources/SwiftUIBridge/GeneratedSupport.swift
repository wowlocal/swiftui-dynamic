import Foundation
import SwiftUI
import SwiftInterpreter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Final host conversions for generated gateways. SwiftUI modifiers and
/// constructors still use ParamSpec for local selection; generated Foundation
/// methods/properties carry parsed HostFunction/HostProperty contracts and use
/// ParamTag only after a method overload has been selected. Hand-written
/// gateways are consulted first and always win.
enum ParamTag: Hashable {
    case string, text, bool, int, double, cgFloat, taskPriority
    case color, font, fontWeight, angle, animation
    case alignment, horizontalAlignment, verticalAlignment, textAlignment
    case edgeSet, unitPoint, contentMode, imageScale, buttonRole
    case symbolRenderingMode
    case bindingBool, bindingString, bindingDouble
    case shapeStyle, genericShapeStyle, anyView, shape
    case visibility, axisSet, edgeInsets, gradient, gridItems
    case axis, colorArray, annotationPosition
    case dimension, measurement
    case builder, action, asyncAction
    case syncVoidClosure, syncCGFloatClosure, equatable
    // Foundation-value tags for the generated-members tier.
    case date, url, data, stringArray
    case decimal, characterSet, indexSet, dateComponents, dateInterval
    case indexPath, intArray, intRange, doubleRange
    case calendarComponent, calendarComponentSet
    /// A concrete contextual value family collected from the SDK interface:
    /// payload-free enum cases or same-type static properties on value types.
    /// The associated value is its normalized Swift type name.
    case sdkEnum(String)
    /// A contextual value manufactured by an SDK protocol extension with a
    /// concrete `Self`, filtered through the generic parameter's full protocol
    /// composition. The associated value is the stable `P&Q` composition key.
    case sdkProtocolValue(String)
    /// A native AppKit/UIKit payload selected from the platform symbol graph.
    case platformValue(String, String)
    /// A platform value accepted by a target SwiftUI overlay but rendered on
    /// the opposite host. The generated semantic adapter consumes the typed
    /// box without pretending its unavailable native payload exists.
    case platformSemanticValue(String, String)
}

struct ParamSpec {
    let label: String?
    let tag: ParamTag
    let hasDefault: Bool
    /// Concrete parameter type read from the SDK interface. Source-declared
    /// extensions can add leading-dot static members to imported types, so
    /// coercion must resolve those members before applying the host adapter.
    let contextualType: String?

    init(
        _ label: String?, _ tag: ParamTag, hasDefault: Bool = false,
        contextualType: String? = nil
    ) {
        self.label = label
        self.tag = tag
        self.hasDefault = hasDefault
        self.contextualType = contextualType
    }
}

/// Wraps an interpreted action closure so it can round-trip through `[Any]`
/// (function types with isolation annotations don't cast reliably through Any).
/// Only ever invoked on the main actor.
struct ActionValue: @unchecked Sendable {
    let run: @MainActor () -> Void
}

/// Async counterpart used only by generated SwiftUI modifier signatures.
/// Its implementation enters a fresh interpreter `.swiftUITask` session;
/// native SwiftUI remains the owner of appearance and cancellation.
struct AsyncActionValue: @unchecked Sendable {
    let run: @MainActor @Sendable () async -> Void
}

/// A synchronous source closure whose argument is manufactured by SwiftUI.
/// The generator selects this by closure shape; the wrapper retains the
/// interpreter context without encoding a modifier or SDK input identity.
/// Result-specific generated adapters either discard or coerce the returned
/// RuntimeValue according to the interface-declared closure result.
struct SyncClosureValue: @unchecked Sendable {
    let closure: ClosureValue
    let context: EvalContext

    @MainActor
    func call(argument: RuntimeValue) throws -> RuntimeValue {
        try context.callHostCallback(closure, arguments: [argument])
    }
}

/// `ViewDimensions` is intentionally non-Sendable even though SwiftUI's
/// callback is `@Sendable`. The callback is synchronous and main-thread-only;
/// erase its argument before the checked actor hop and carry that immutable
/// runtime value through an explicitly unchecked box.
private struct SyncClosureRuntimeArgument: @unchecked Sendable {
    let value: RuntimeValue
}

/// Keeps generated result-builder arguments lazy while overload labels and
/// scalar argument types are matched. Eagerly evaluating a builder during
/// matching swallowed errors from nested views and replaced them with a
/// misleading "no matching initializer" error on the outer container.
struct BuilderValue {
    let value: RuntimeValue
    let context: EvalContext
}

struct GeneratedOverload {
    let params: [ParamSpec]
    /// Interface-declared overload preference. Dispatch keeps viable favored
    /// declarations ahead of `@_disfavoredOverload` fallbacks.
    let isDisfavored: Bool
    /// Modules required by the interpreted source target, independently of
    /// which platform compiled this host bridge.
    let requiredImports: Set<String>
    /// Whether the compiled adapter evaluates ViewBuilder arguments. An
    /// off-host receiver-preserving fallback accepts the source call shape
    /// without inventing deferred-content execution.
    let executesBuilderArguments: Bool
    /// Optional SwiftUI runtime behavior absent from the interface. BridgeGen
    /// selects this from a protocol value's concrete semantic property, never
    /// from an app, fixture, literal, or interpreted call site.
    let semanticAdapter: GeneratedModifierSemanticAdapter?
    let invoke: @MainActor (AnyView, [Any]) throws -> AnyView
}

struct GeneratedConstructor {
    let params: [ParamSpec]
    let isDisfavored: Bool
    let invoke: @MainActor ([Any]) throws -> Any

    init(
        params: [ParamSpec],
        isDisfavored: Bool = false,
        invoke: @escaping @MainActor ([Any]) throws -> Any
    ) {
        self.params = params
        self.isDisfavored = isDisfavored
        self.invoke = invoke
    }
}

/// Generated overloads grouped once by the only arity that can match. This
/// replaces sorting and scanning every generated candidate on every call.
struct GeneratedOverloadSet {
    let byArity: [Int: [GeneratedOverload]]
    let count: Int

    init(_ overloads: [GeneratedOverload]) {
        var byArity: [Int: [GeneratedOverload]] = [:]
        for overload in overloads where !overload.isDisfavored {
            byArity[overload.params.count, default: []].append(overload)
        }
        for overload in overloads where overload.isDisfavored {
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
        for overload in overloads where !overload.isDisfavored {
            byArity[overload.params.count, default: []].append(overload)
        }
        for overload in overloads where overload.isDisfavored {
            byArity[overload.params.count, default: []].append(overload)
        }
        self.byArity = byArity
        self.count = overloads.count
    }
}

private extension RuntimeValue {
    var isUnresolvedContextualMember: Bool {
        if case .implicitMember = self { return true }
        guard case .host(let payload) = self else { return false }
        return payload is ImplicitMemberCall || payload is ChainedImplicitCall
    }
}

enum GeneratedDispatch {
    /// Retain narrowly handwritten SwiftUI-magic execution while exposing
    /// the overload shapes BridgeGen read from the swiftinterface. Both real
    /// and trace registries use this composition, so a semantic gateway
    /// cannot discard interface-derived overload metadata.
    static func exposingInterfaceMetadata(
        for modifier: HostModifier, named name: String
    ) -> HostModifier {
        guard let overloads = GeneratedModifiers.table[name] else {
            return modifier
        }
        return HostModifier(
            name: name,
            parameterTypeCandidates: { args, ctx in
                contextualParameterTypeCandidates(
                    overloads: overloads, args: args, ctx: ctx)
            },
            argumentMatch: { args, ctx in
                contextualArgumentsMatch(
                    overloads: overloads, args: args, ctx: ctx)
            },
            apply: modifier.apply)
    }

    /// A leading-dot initializer is contextual syntax: `.init(...)` names
    /// the constructor of the parameter type supplied by the interface.
    /// Keep the original arguments and evaluation context so nested source
    /// statics are resolved by the generated constructor just as they are in
    /// an explicit `Type(...)` call.
    private static func generatedContextualInitializer(
        _ value: RuntimeValue,
        contextualType: String,
        context: EvalContext
    ) throws -> RuntimeValue? {
        guard case .host(let payload) = value,
              let call = payload as? ImplicitMemberCall,
              call.name == "init" else {
            return nil
        }
        let typeName = GeneratedPlatformBridge.canonicalTypeName(
            contextualType)
        guard GeneratedConstructors.table[typeName] != nil
                || GeneratedMembers.nativeValueConstructors[typeName] != nil
        else {
            return nil
        }
        return try context.invokeHostConstructor(
            named: typeName, arguments: call.arguments)
    }

    static func coerce(
        _ tag: ParamTag, _ unresolvedValue: RuntimeValue,
        _ ctx: EvalContext, contextualType: String? = nil
    ) throws -> Any {
        let value: RuntimeValue
        if case .implicitMember(let member) = unresolvedValue,
           let contextualType,
           let resolved = try ctx.sourceStaticMember(
            named: member, ofType: contextualType) {
            value = resolved
        } else if let contextualType,
                  let initialized = try generatedContextualInitializer(
                    unresolvedValue,
                    contextualType: contextualType,
                    context: ctx) {
            value = initialized
        } else {
            value = unresolvedValue
        }
        switch tag {
        case .string:
            guard let s = value.stringValue else { throw RuntimeError(message: "expected a String") }
            return s
        case .text:
            if case .host(let any) = value, let box = any as? TextBox { return box.text }
            if let string = value.stringValue { return Text(string) }
            throw RuntimeError(message: "expected Text or a String")
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
        case .taskPriority:
            if let priority = value.hostPayload as? TaskPriority {
                return priority
            }
            if let priority = value.hostPayload as? RuntimeTaskPriority {
                return TaskPriority(rawValue: priority.rawValue)
            }
            let member: String?
            switch value {
            case .implicitMember(let name):
                member = name
            case .host(let call as ImplicitMemberCall):
                member = call.name
            default:
                member = nil
            }
            switch member {
            case "high", "userInitiated": return TaskPriority.high
            case "medium": return TaskPriority.medium
            case "low", "utility": return TaskPriority.low
            case "background": return TaskPriority.background
            default:
                throw RuntimeError(message:
                    "expected a TaskPriority implicit member")
            }
        case .color:
            return try Coerce.color(value)
        case .font:
            return try TargetPlatformTypographyBridge.font(
                from: value, context: ctx)
        case .fontWeight:
            return try Coerce.fontWeight(value)
        case .symbolRenderingMode:
            guard case .implicitMember(let name) = value else {
                throw RuntimeError(message: "expected a symbol rendering mode like .palette")
            }
            switch name {
            case "palette": return SymbolRenderingMode.palette
            case "hierarchical": return SymbolRenderingMode.hierarchical
            case "multicolor": return SymbolRenderingMode.multicolor
            case "monochrome": return SymbolRenderingMode.monochrome
            default:
                throw RuntimeError(message: "unknown symbol rendering mode '.\(name)'")
            }
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
        case .genericShapeStyle:
            return try Coerce.genericShapeStyle(value)
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
            guard value.closureValue != nil else { throw RuntimeError(message: "expected a view closure") }
            return BuilderValue(value: value, context: ctx)
        case .action:
            guard let closure = value.closureValue else { throw RuntimeError(message: "expected a closure") }
            let callback = InterpretedHostCallback(
                closure: closure,
                context: ctx,
                diagnosticContext: "generated action")
            return ActionValue(run: { callback.call() })
        case .asyncAction:
            guard let closure = value.closureValue else {
                throw RuntimeError(message: "expected an async closure")
            }
            let callback = InterpretedSwiftUITaskCallback(
                closure: closure,
                context: ctx,
                diagnosticContext: "generated SwiftUI async action")
            return AsyncActionValue(run: { await callback.call() })
        case .syncVoidClosure, .syncCGFloatClosure:
            guard let closure = value.closureValue else {
                throw RuntimeError(message: "expected a synchronous closure")
            }
            return SyncClosureValue(closure: closure, context: ctx)
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
        case .doubleRange:
            // `in: 0...10` — interpreted ranges carry runtime bounds; Int
            // bounds promote (Gauge/Slider ranges are written both ways).
            if let runtime = value.rangeValue, runtime.includesUpperBound,
               let lower = runtime.lowerBound?.doubleValue,
               let upper = runtime.upperBound?.doubleValue {
                return lower...upper
            }
            if let closed: ClosedRange<Double> = hostValue(value) { return closed }
            throw RuntimeError(message: "expected a closed range (ClosedRange<Double>) like 0...1")
        case .annotationPosition:
            return Coerce.annotationPosition(value)
        case .dimension:
            return try Coerce.dimension(value)
        case .measurement:
            if case .host(let any) = value, let measurement = any as? Measurement<Dimension> {
                return measurement
            }
            if let carrier = value.hostPayload as? Measurement<Dimension> { return carrier }
            throw RuntimeError(message: "expected a Measurement value")
        case .calendarComponent:
            return try Coerce.calendarComponent(value)
        case .calendarComponentSet:
            // Native code writes `[.year, .month]` — Set's array-literal
            // conformance; the interpreted array coerces element-wise.
            guard let array = value.collectionElements else {
                throw RuntimeError(message: "expected a set of calendar components")
            }
            return Set(try array.map(Coerce.calendarComponent))
        case .sdkEnum(let typeName):
            return try GeneratedSDKEnumCoercions.coerce(typeName, value)
        case .sdkProtocolValue(let composition):
            return try GeneratedSDKProtocolValueCoercions.coerce(
                composition, value, context: ctx)
        case .platformValue(let framework, let typeName):
            let resolved: RuntimeValue
            if case .implicitMember(let member) = value,
               let memberValue = GeneratedPlatformBridge.staticMember(
                member, typeName: typeName) {
                resolved = memberValue
            } else {
                resolved = value
            }
            guard case .host(let any) = resolved,
                  let carrier = any as? GeneratedPlatformSemanticCarrier,
                  carrier.generatedPlatformFramework == framework,
                  GeneratedPlatformBridge.typeCandidates(
                    framework: framework,
                    type: carrier.generatedPlatformTypeName
                  ).contains(typeName),
                  let payload = carrier.generatedPlatformNativePayload else {
                throw RuntimeError(message:
                    "expected a native \(framework).\(typeName) value")
            }
            return payload
        case .platformSemanticValue(let framework, let typeName):
            let resolved: RuntimeValue
            if case .implicitMember(let member) = value,
               let memberValue = GeneratedPlatformBridge.staticMember(
                member, typeName: typeName) {
                resolved = memberValue
            } else {
                resolved = value
            }
            guard case .host(let any) = resolved,
                  let carrier = any as? GeneratedPlatformSemanticCarrier,
                  carrier.generatedPlatformFramework == framework,
                  GeneratedPlatformBridge.typeCandidates(
                    framework: framework,
                    type: carrier.generatedPlatformTypeName
                  ).contains(typeName) else {
                throw RuntimeError(message:
                    "expected a generated \(framework).\(typeName) value")
            }
            return carrier
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

    private static func labelsMatch(
        _ params: [ParamSpec], _ args: CallArguments
    ) -> Bool {
        guard params.count == args.arguments.count else { return false }
        for (param, argument) in zip(params, args.arguments) {
            let isClosureParam = param.tag == .builder
                || param.tag == .action
                || param.tag == .asyncAction
                || param.tag == .syncVoidClosure
                || param.tag == .syncCGFloatClosure
            guard argument.label == param.label
                || (argument.isTrailing && argument.label == nil
                    && isClosureParam)
            else {
                return false
            }
        }
        return true
    }

    private static func matches(_ params: [ParamSpec], _ args: CallArguments, _ ctx: EvalContext) -> [Any]? {
        guard labelsMatch(params, args) else { return nil }
        var values: [Any] = []
        for (param, argument) in zip(params, args.arguments) {
            guard let coerced = try? coerce(
                    param.tag, argument.value, ctx,
                    contextualType: param.contextualType) else { return nil }
            values.append(coerced)
        }
        return values
    }

    /// Return every interface-derived contextual type shape that can accept
    /// these labels and arity. Unlike matchingParameters, this deliberately
    /// performs no coercion, so overload resolution can inspect metadata
    /// without triggering source static initialization.
    static func contextualParameterTypeCandidates(
        overloads: GeneratedOverloadSet,
        args: CallArguments,
        ctx: EvalContext
    ) -> [[String?]] {
        (overloads.byArity[args.arguments.count] ?? []).compactMap {
            guard isAvailable($0, in: ctx),
                  labelsMatch($0.params, args) else {
                return nil
            }
            return $0.params.map(\.contextualType)
        }
    }

    /// Whether an interface-shaped overload can consume every unresolved
    /// leading-dot marker through the adapter's own static coercions. Passing
    /// no contextual type intentionally excludes interpreted extension
    /// statics; the core resolver proves those from declaration metadata.
    static func contextualArgumentsMatch(
        overloads: GeneratedOverloadSet,
        args: CallArguments,
        ctx: EvalContext
    ) -> Bool {
        for overload in overloads.byArity[args.arguments.count] ?? [] {
            guard isAvailable(overload, in: ctx),
                  labelsMatch(overload.params, args) else {
                continue
            }
            var matches = true
            for (param, argument) in zip(
                overload.params, args.arguments
            ) where argument.value.isUnresolvedContextualMember {
                do {
                    _ = try coerce(
                        param.tag, argument.value, ctx,
                        contextualType: nil)
                } catch {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    /// Return the interface-derived parameter shape selected by the same
    /// coercion and label rules as generated dispatch. Semantic adapters can
    /// preserve closure properties without redispatching on an API name.
    static func matchingParameters(
        overloads: GeneratedOverloadSet,
        args: CallArguments,
        ctx: EvalContext
    ) -> [ParamSpec]? {
        for overload in overloads.byArity[args.arguments.count] ?? []
        where isAvailable(overload, in: ctx)
            && matches(overload.params, args, ctx) != nil {
            return overload.params
        }
        return nil
    }

    static func isAvailable(
        _ overload: GeneratedOverload,
        in ctx: EvalContext
    ) -> Bool {
        guard !overload.requiredImports.isEmpty else { return true }
        guard let interpreter = ctx as? Interpreter else { return false }
        return overload.requiredImports.allSatisfy {
            interpreter.buildConfiguration.canImport($0)
        }
    }

    static func dispatch(
        name: String,
        overloads: GeneratedOverloadSet,
        view: AnyView,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> AnyView {
        for overload in overloads.byArity[args.arguments.count] ?? [] {
            guard isAvailable(overload, in: ctx) else { continue }
            guard let values = matches(overload.params, args, ctx) else { continue }
            let native = try overload.invoke(view, values)
            guard let adapter = overload.semanticAdapter else {
                return native
            }
            return adapter.apply(
                to: native, receiver: view, values: values, context: ctx)
        }
        let shape = args.arguments.map { $0.label ?? "_" }.joined(separator: ":")
        throw RuntimeError(message: "no matching overload for .\(name)(\(shape):) — argument types or labels don't fit")
    }

    static func construct(
        name: String,
        overloads: GeneratedConstructorSet,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> Any {
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

/// One generated property gateway plus its copy-out mutation. The cached
/// HostProperty owns validation for ordinary reads/reference-backed writes;
/// value lvalues reuse `mutate` and install the returned SDK value in their
/// owning storage.
struct GeneratedMemberProperty {
    typealias Mutation = (Any, RuntimeValue) throws -> Any

    let contract: HostProperty
    let mutate: Mutation?

    var signature: HostSignature { contract.signature }
    var name: String { contract.name }

    func read(
        from receiver: RuntimeValue, in context: EvalContext
    ) throws -> RuntimeValue {
        try contract.read(from: receiver, in: context)
    }

    func write(
        _ value: RuntimeValue, to receiver: RuntimeValue,
        in context: EvalContext
    ) throws {
        try contract.write(value, to: receiver, in: context)
    }
}

/// Namespace the generated members file extends with `buildProperties()` /
/// `buildMethods()`. Keys are "TypeName.memberName" against the receiver's
/// logical SDK type, so hand boxes can expose their wrapped value without
/// weakening receiver validation.
enum GeneratedMembers {
    static let properties: [String: GeneratedMemberProperty] = buildProperties()

    static let methods: [String: GeneratedMemberSet] = {
        var grouped: [String: GeneratedMemberSet] = [:]
        for (key, overloads) in buildMethods() {
            grouped[key] = GeneratedMemberSet(overloads)
        }
        return grouped
    }()

    static func parseConstructorContract(
        _ declaration: String
    ) -> HostSignature {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard signature.kind == .initializer,
                  signature.isThrowing else {
                preconditionFailure(
                    "BridgeGen emitted a nonthrowing constructor contract '\(declaration)'")
            }
            return signature
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid constructor contract '\(declaration)': \(error)")
        }
    }

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
        _ table: inout [String: GeneratedMemberProperty],
        _ declaration: String,
        get: @escaping (Any) -> RuntimeValue?,
        mutate: GeneratedMemberProperty.Mutation? = nil
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard signature.kind == .property,
                  let receiverType = signature.receiverType else {
                preconditionFailure(
                    "BridgeGen emitted inconsistent property metadata for '\(declaration)'")
            }
            let property = try makeProperty(
                signature: signature, declaration: declaration,
                unwrapCarrierForGet: true, get: get, mutate: mutate)
            let key = "\(receiverType).\(signature.name)"
            guard table[key] == nil else {
                preconditionFailure(
                    "BridgeGen emitted duplicate property metadata for '\(declaration)'")
            }
            table[key] = GeneratedMemberProperty(
                contract: property, mutate: mutate)
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid host property '\(declaration)': \(error)")
        }
    }

    private static func makeProperty(
        signature: HostSignature,
        declaration: String,
        unwrapCarrierForGet: Bool,
        get: @escaping (Any) -> RuntimeValue?,
        mutate: GeneratedMemberProperty.Mutation?
    ) throws -> HostProperty {
        let setter: HostProperty.Setter?
        if let mutate {
            setter = { receiver, newValue, _ in
                guard let rawReceiver = receiver.hostPayload else {
                    throw RuntimeError(
                        message: "generated property '\(declaration)' received no host payload",
                        fatal: true)
                }
                let logicalReceiver = (rawReceiver as? GeneratedMemberCarrier)?
                    .generatedMemberValue ?? rawReceiver
                let updated = try mutate(logicalReceiver, newValue)
                guard let carrier = rawReceiver as? GeneratedMemberCarrier,
                      carrier.writeGeneratedMemberValue(updated) else {
                    throw RuntimeError(message:
                        "cannot assign to '\(signature.name)' without mutable host-value storage")
                }
            }
        } else {
            setter = nil
        }
        return try HostProperty(
            signature: signature,
            get: { receiver, _ in
                guard let rawReceiver = receiver.hostPayload else {
                    throw RuntimeError(
                        message: "generated property '\(declaration)' received no host payload",
                        fatal: true)
                }
                let getterReceiver: Any
                if unwrapCarrierForGet,
                   let carrier = rawReceiver as? GeneratedMemberCarrier {
                    getterReceiver = carrier.generatedMemberValue
                } else {
                    getterReceiver = rawReceiver
                }
                guard let value = get(getterReceiver) else {
                    throw RuntimeError(
                        message: "generated property '\(declaration)' receiver downcast failed",
                        fatal: true)
                }
                return value
            },
            set: setter)
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
        if let nested = runtimeNestedTypeNames[name] { return nested }
        if name == "NSDecimal" { return "Decimal" }
        // Generic carriers key on the base name; the runtime prints the
        // ObjC-renamed argument (Measurement<NSDimension>).
        if name.hasPrefix("Measurement<") { return "Measurement" }
        return name
    }

    static func member(_ name: String, on value: Any) -> RuntimeValue? {
        method(name, on: value)
    }

    static func propertyKey(_ name: String, on value: Any) -> String {
        let logicalReceiver = (value as? GeneratedMemberCarrier)?
            .generatedMemberValue ?? value
        return "\(keyTypeName(of: logicalReceiver)).\(name)"
    }

    static func property(_ name: String, on value: Any) -> HostProperty? {
        properties[propertyKey(name, on: value)]?.contract
    }

    static func adapting(
        _ property: GeneratedMemberProperty,
        get: @escaping (Any) -> RuntimeValue?
    ) -> HostProperty {
        do {
            return try makeProperty(
                signature: property.contract.signature,
                declaration: property.contract.signature.declaration,
                unwrapCarrierForGet: false, get: get,
                mutate: property.mutate)
        } catch {
            preconditionFailure(
                "cached generated property became invalid: \(error)")
        }
    }

    /// Mutate a logical SDK copy, then re-wrap it when the runtime receiver
    /// is a compatibility carrier. Conversion errors are deliberately
    /// throwable: a contextual enum case such as `.notACachePolicy` must not
    /// degrade into the same diagnostic as a missing property.
    static func mutatedCopy(
        setting name: String, on value: Any, to newValue: RuntimeValue
    ) throws -> Any? {
        let logicalReceiver = (value as? GeneratedMemberCarrier)?
            .generatedMemberValue ?? value
        let key = "\(keyTypeName(of: logicalReceiver)).\(name)"
        guard let mutate = properties[key]?.mutate else { return nil }
        let updated = try mutate(logicalReceiver, newValue)
        if let carrier = value as? GeneratedMemberCarrier {
            return carrier.replacingGeneratedMemberValue(updated)
        }
        return updated
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

/// Interface-generated receivers of a generic metatype subscript. The host
/// bridge dispatches on this capability; Foundation receiver identities and
/// key metatypes stay confined to generated code.
protocol GeneratedMetatypeSubscriptCarrier {
    func generatedMetatypeSubscript(
        typeNamed typeName: String
    ) -> RuntimeValue?
}

/// A concrete SDK value used by another generated initializer contract keeps
/// its native representation across registries. BridgeGen selects both the
/// type and its callable shapes transitively from interface metadata.
@MainActor
func generatedNativeValueConstructor(
    named name: String
) -> HostFunction? {
    guard let overloads =
            GeneratedMembers.nativeValueConstructors[name] else {
        return nil
    }
    return HostFunction(name: name) { arguments, context in
        .native(try GeneratedDispatch.construct(
            name: name,
            overloads: overloads,
            args: arguments,
            ctx: context))
    }
}

extension GeneratedDispatch {
    /// Interface-declared throwing initializers own calls whose LABEL SHAPE
    /// matches them, even when their native implementation still lives in a
    /// compatibility gateway. Validate those calls against cached SDK types
    /// before the gateway can coerce an opaque imported value into a concrete
    /// result. Other legacy constructor shapes retain their existing path.
    static func validatingThrowingConstructor(
        named name: String,
        implementation: HostFunction
    ) -> HostFunction {
        guard let contracts = GeneratedMembers
            .throwingConstructorContracts[name],
              !contracts.isEmpty else { return implementation }

        return HostFunction(name: implementation.name) { args, context in
            let shaped = contracts.filter {
                $0.matchesArgumentShape(args)
            }
            guard !shaped.isEmpty else {
                return try implementation.invoke(args, context)
            }

            let matches = shaped.compactMap { signature -> (
                signature: HostSignature, match: HostCallMatch
            )? in
                signature.match(arguments: args, in: context).map {
                    (signature, $0)
                }
            }
            guard let selected = matches.max(by: {
                $0.match.score < $1.match.score
            }) else {
                // Produce the typed argument diagnostic from the interface
                // declaration instead of letting the compatibility gateway
                // silently default a value it cannot coerce.
                _ = try shaped[0].validate(arguments: args, in: context)
                preconditionFailure("a validated constructor call had no match")
            }

            let result = try implementation.invoke(args, context)
            try selected.signature.validateReturn(
                result, match: selected.match, in: context)
            return result
        }
    }

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

/// SDK arrays cross into the interpreter's array plane element-wise —
/// `DateBins.thresholds: [Date]` must answer `.count`/subscripts/iteration
/// like any interpreted array, not ride as an opaque host payload. The
/// DISTINCT name is load-bearing: BridgeGen picks it at emit time for
/// array-typed contracts only, so it never re-ranks member overload
/// resolution inside emitted closures (Sequence.dropLast would otherwise
/// beat IndexPath.dropLast on the [Element] parameter match).
func generatedMemberArrayResult<Element>(_ value: [Element]) -> RuntimeValue {
    .array(value.map { RuntimeValue.native($0 as Any) })
}

/// A generated SDK sequence retains its interface-declared nominal type for
/// host-contract validation while exposing one finite element plane to the
/// interpreter's property-based collection machinery.
@MainActor
final class GeneratedMemberSequenceCarrier:
    RuntimeMaterializedSequence, GeneratedMemberCarrier {
    let generatedSourceTypeName: String
    let generatedSourceProtocolNames: [String]
    let runtimeMaterializedElements: [RuntimeValue]
    let generatedMemberValue: Any

    init(
        sourceTypeName: String, sourceProtocolNames: [String],
        elements: [RuntimeValue], sourceValue: Any
    ) {
        generatedSourceTypeName = sourceTypeName
        generatedSourceProtocolNames = sourceProtocolNames
        runtimeMaterializedElements = elements
        generatedMemberValue = sourceValue
    }
}

/// Any SDK sequence selected from interface-declared conformance metadata
/// crosses through that carrier. Protocol capabilities are read from the
/// concrete value's conformance shape, never from a nominal identity table.
func generatedMemberSequenceResult<Elements: Sequence>(
    _ value: Elements
) -> RuntimeValue {
    let protocols: [String]
    if value is any RandomAccessCollection {
        protocols = [
            "RandomAccessCollection", "BidirectionalCollection",
            "Collection", "Sequence",
        ]
    } else if value is any BidirectionalCollection {
        protocols = ["BidirectionalCollection", "Collection", "Sequence"]
    } else if value is any Collection {
        protocols = ["Collection", "Sequence"]
    } else {
        protocols = ["Sequence"]
    }
    return .native(GeneratedMemberSequenceCarrier(
        sourceTypeName: GeneratedMembers.keyTypeName(of: value),
        sourceProtocolNames: protocols,
        elements: value.map { RuntimeValue.native($0 as Any) },
        sourceValue: value))
}

func generatedMemberResult(_ value: Any) -> RuntimeValue {
    .native(value)
}

/// Structural conversion used only after HostProperty has accepted an
/// assignment. Native payloads take the zero-allocation cast path; source
/// arrays/dictionaries and empty Optionals recursively acquire the static SDK
/// type emitted by BridgeGen.
private protocol GeneratedPropertyRuntimeConvertible {
    static func generatedPropertyValue(from value: RuntimeValue) throws -> Any
}

func convertGeneratedPropertyValue<T>(
    _ value: RuntimeValue, as _: T.Type
) throws -> T {
    if let direct = value.hostPayload as? T { return direct }
    if let carrier = value.hostPayload as? GeneratedMemberCarrier,
       let unwrapped = carrier.generatedMemberValue as? T {
        return unwrapped
    }
    if case .implicitMember(let name) = value,
       let implicit: T = generatedURLRequestPropertyValue(name, as: T.self) {
        return implicit
    }
    if let convertible = T.self as? GeneratedPropertyRuntimeConvertible.Type,
       let converted = try convertible.generatedPropertyValue(from: value) as? T {
        return converted
    }
    throw RuntimeError(message:
        "cannot convert '\(value.stringified)' to generated property type '\(String(describing: T.self))'")
}

extension Optional: GeneratedPropertyRuntimeConvertible {
    fileprivate static func generatedPropertyValue(
        from value: RuntimeValue
    ) throws -> Any {
        switch value.optionalState {
        case .none:
            let result: Wrapped? = nil
            return result as Any
        case .some(let wrapped, _):
            let result: Wrapped? = try convertGeneratedPropertyValue(
                wrapped, as: Wrapped.self)
            return result as Any
        case .notOptional:
            if case .implicitMember("none") = value {
                let result: Wrapped? = nil
                return result as Any
            }
            let result: Wrapped? = try convertGeneratedPropertyValue(
                value, as: Wrapped.self)
            return result as Any
        }
    }
}

extension Array: GeneratedPropertyRuntimeConvertible {
    fileprivate static func generatedPropertyValue(
        from value: RuntimeValue
    ) throws -> Any {
        guard let elements = value.arrayValue else {
            throw RuntimeError(message: "expected an Array property value")
        }
        return try elements.map {
            try convertGeneratedPropertyValue($0, as: Element.self)
        }
    }
}

extension Dictionary: GeneratedPropertyRuntimeConvertible {
    fileprivate static func generatedPropertyValue(
        from value: RuntimeValue
    ) throws -> Any {
        guard let dictionary = value.dictValue else {
            throw RuntimeError(message: "expected a Dictionary property value")
        }
        var result: [Key: Value] = [:]
        for (key, entry) in zip(dictionary.keys, dictionary.values) {
            result[try convertGeneratedPropertyValue(key, as: Key.self)] =
                try convertGeneratedPropertyValue(entry, as: Value.self)
        }
        return result
    }
}

private func generatedURLRequestPropertyValue<T>(
    _ name: String, as type: T.Type
) -> T? {
    let value: Any?
    if type == URLRequest.CachePolicy.self {
        switch name {
        case "useProtocolCachePolicy": value = URLRequest.CachePolicy.useProtocolCachePolicy
        case "reloadIgnoringLocalCacheData": value = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        case "reloadIgnoringLocalAndRemoteCacheData": value = URLRequest.CachePolicy.reloadIgnoringLocalAndRemoteCacheData
        case "returnCacheDataElseLoad": value = URLRequest.CachePolicy.returnCacheDataElseLoad
        case "returnCacheDataDontLoad": value = URLRequest.CachePolicy.returnCacheDataDontLoad
        case "reloadRevalidatingCacheData": value = URLRequest.CachePolicy.reloadRevalidatingCacheData
        default: value = nil
        }
    } else if type == URLRequest.NetworkServiceType.self {
        switch name {
        case "default": value = URLRequest.NetworkServiceType.default
        // The SDK keeps the deprecated `.voip` case at raw value 1. Using
        // RawRepresentable here lets legacy source remain contextualizable
        // without baking a deprecation warning into every bridge build.
        case "voip": value = URLRequest.NetworkServiceType(rawValue: 1)!
        case "video": value = URLRequest.NetworkServiceType.video
        case "background": value = URLRequest.NetworkServiceType.background
        case "voice": value = URLRequest.NetworkServiceType.voice
        case "responsiveData": value = URLRequest.NetworkServiceType.responsiveData
        case "avStreaming": value = URLRequest.NetworkServiceType.avStreaming
        case "callSignaling": value = URLRequest.NetworkServiceType.callSignaling
        default: value = nil
        }
    } else if type == URLRequest.Attribution.self {
        switch name {
        case "developer": value = URLRequest.Attribution.developer
        case "user": value = URLRequest.Attribution.user
        default: value = nil
        }
    } else {
        value = nil
    }
    return value as? T
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
        requiredImports: Set<String> = [],
        isDisfavored: Bool = false,
        executesBuilderArguments: Bool = true,
        semanticAdapter: GeneratedModifierSemanticAdapter? = nil,
        _ invoke: @escaping @MainActor (AnyView, [Any]) throws -> AnyView
    ) {
        table[name, default: []].append(GeneratedOverload(
            params: params,
            isDisfavored: isDisfavored,
            requiredImports: requiredImports,
            executesBuilderArguments: executesBuilderArguments,
            semanticAdapter: semanticAdapter,
            invoke: invoke))
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
        isDisfavored: Bool = false,
        _ invoke: @escaping @MainActor ([Any]) throws -> Any
    ) {
        table[name, default: []].append(GeneratedConstructor(
            params: params,
            isDisfavored: isDisfavored,
            invoke: invoke))
    }
}

/// A target-specific platform color has no native payload on the opposite
/// host. The target overlay nevertheless proves that it initializes a value
/// which is both View and ShapeStyle, so preserve that semantic capability as
/// a real Color instead of leaking an inert platform stub into rendering.
/// Native payloads retain their exact conversion; unavailable payloads use a
/// deterministic dynamic foreground style without inspecting SDK identities.
@MainActor
func generatedPlatformShapeStyleValue(_ value: Any) -> Any {
    guard let carrier = value as? GeneratedPlatformSemanticCarrier else {
        return Color.secondary
    }
#if canImport(AppKit)
    if let color = carrier.generatedPlatformNativePayload as? NSColor {
        return Color(nsColor: color)
    }
#endif
#if canImport(UIKit)
    if let color = carrier.generatedPlatformNativePayload as? UIColor {
        return Color(uiColor: color)
    }
#endif
    return Color.secondary
}

/// A target-platform payload may carry a native-equivalent primitive View
/// even when its framework is unavailable to this host. BridgeGen emits this
/// adapter from the structural shape "View initializer with one platform
/// value"; the payload capability supplies the renderable value, so runtime
/// dispatch contains no constructor or SDK identity.
@MainActor
func generatedPlatformViewValue(_ value: Any) throws -> Any {
    guard let carrier = value as? GeneratedPlatformSemanticCarrier,
          let view = carrier.generatedPlatformViewValue else {
        throw RuntimeError(message:
            "platform value has no transferable SwiftUI View semantics")
    }
    return view
}

/// Bridges an ActionValue (from `[Any]`) into the plain `() -> Void` shape
/// framework APIs take; safe because SwiftUI invokes these on the main thread.
nonisolated func generatedAction(_ value: Any) -> () -> Void {
    let action = value as! ActionValue
    return { MainActor.assumeIsolated { action.run() } }
}

/// Bridges generated async modifier arguments without encoding any modifier
/// name or lifecycle rule in the generated surface.
func generatedAsyncAction(
    _ value: Any
) -> @MainActor @Sendable () async -> Void {
    let action = value as! AsyncActionValue
    return { await action.run() }
}

/// Adapts any framework-supplied callback input to the interpreter's
/// native-value boundary. Result-specific overloads share one callback value;
/// their shapes come directly from the SDK interface.
nonisolated func generatedSyncVoidClosure<Input>(
    _ value: Any
) -> @Sendable (Input) -> Void {
    let callback = value as! SyncClosureValue
    return { input in
        let argument = SyncClosureRuntimeArgument(value: .host(input))
        MainActor.assumeIsolated {
            do {
                _ = try callback.call(argument: argument.value)
            } catch let error as RuntimeError {
                RenderDiagnostics.record(
                    error, in: "generated synchronous Void closure")
            } catch {
                RenderDiagnostics.record(
                    RuntimeError(message: String(describing: error)),
                    in: "generated synchronous Void closure")
            }
        }
    }
}

nonisolated func generatedSyncCGFloatClosure<Input>(
    _ value: Any
) -> @Sendable (Input) -> CGFloat {
    let callback = value as! SyncClosureValue
    return { input in
        let argument = SyncClosureRuntimeArgument(value: .host(input))
        return MainActor.assumeIsolated {
            do {
                return try Coerce.cgFloat(
                    callback.call(argument: argument.value))
            } catch let error as RuntimeError {
                RenderDiagnostics.record(
                    error, in: "generated synchronous CGFloat closure")
            } catch {
                RenderDiagnostics.record(
                    RuntimeError(message: String(describing: error)),
                    in: "generated synchronous CGFloat closure")
            }
            return 0
        }
    }
}

/// Evaluates a generated zero-input `@ViewBuilder` only after its overload has
/// been selected, preserving any nested render error and its source location.
func generatedBuilder(_ value: Any) throws -> AnyView {
    guard let builder = value as? BuilderValue,
          let closure = builder.value.closureValue else {
        throw RuntimeError(message: "expected a view closure")
    }
    let views = try builder.context.callBuilderClosure(closure, arguments: [])
        .map(ViewRegistry.anyView)
    // NEUTRAL fan-out: the receiving container must see the children as
    // ITS children (HSplitView panes, Group members...). A VStack wrap
    // collapsed every multi-child generated container into one cell.
    return views.count == 1 ? views[0] : AnyView(ViewRegistry.indexed(views))
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
        // `.init()` / `.init(top:leading:bottom:trailing:)` — implicit
        // member markers resolve against the expected type here, like every
        // other expected-type-context coercion.
        if case .host(let any) = value, let call = any as? ImplicitMemberCall,
           call.name == "init" {
            return EdgeInsets(
                top: (try? cgFloat(call.arguments.labeled("top") ?? .native(0.0))) ?? 0,
                leading: (try? cgFloat(call.arguments.labeled("leading") ?? .native(0.0))) ?? 0,
                bottom: (try? cgFloat(call.arguments.labeled("bottom") ?? .native(0.0))) ?? 0,
                trailing: (try? cgFloat(call.arguments.labeled("trailing") ?? .native(0.0))) ?? 0)
        }
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
    /// Reference carriers install an updated SDK value in place. Value
    /// carriers use the replacement hook below and keep this default.
    func writeGeneratedMemberValue(_ value: Any) -> Bool
    /// Re-box an updated SDK value for a value-lvalue transaction.
    func replacingGeneratedMemberValue(_ value: Any) -> Any?
}

/// Property-based carrier shared by every Foundation attributed-text value
/// the generated member tier reaches. Full strings and styled slices normalize
/// to the same host value for Text construction and protocol `+` dispatch.
protocol GeneratedAttributedTextCarrier {
    var generatedAttributedText: AttributedString { get }
}

extension AttributedString: GeneratedAttributedTextCarrier {
    var generatedAttributedText: AttributedString { self }
}

extension AttributedSubstring: GeneratedAttributedTextCarrier {
    var generatedAttributedText: AttributedString { AttributedString(self) }
}

/// Opaque attributed indices remain native. Their Range acquires one semantic
/// capability so every attributed-text carrier can consume it without a
/// source/API-name branch.
protocol GeneratedAttributedTextRangeCarrier {
    var generatedAttributedTextRange: Range<AttributedString.Index> { get }
}

extension Range: GeneratedAttributedTextRangeCarrier
where Bound == AttributedString.Index {
    var generatedAttributedTextRange: Range<AttributedString.Index> { self }
}

private func generatedAttributedText(
    from value: RuntimeValue
) -> AttributedString? {
    guard case .host(let payload) = value else { return nil }
    if let carrier = payload as? GeneratedAttributedTextCarrier {
        return carrier.generatedAttributedText
    }
    if let memberCarrier = payload as? GeneratedMemberCarrier,
       let carrier = memberCarrier.generatedMemberValue
        as? GeneratedAttributedTextCarrier {
        return carrier.generatedAttributedText
    }
    return nil
}

/// The Foundation interface declares `AttributedString + some
/// AttributedStringProtocol`. Normalize both generated carriers to concrete
/// AttributedString values, preserving content and attributes through the
/// operator without depending on either carrier's nominal identity.
func generatedAttributedTextCombination(
    _ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue
) -> RuntimeValue? {
    guard op == "+",
          var left = generatedAttributedText(from: lhs),
          let right = generatedAttributedText(from: rhs) else { return nil }
    left.append(right)
    return .native(AttributedStringBox(left))
}

/// An opaque native carrier whose interface-declared binary operator retains
/// a concrete result type. Dispatch asks for this semantic property instead
/// of branching on an SDK type or consumer identity; additional mapped
/// carriers can adopt the same adapter without growing the registry surface.
protocol GeneratedBinaryOperatorCarrier {
    func applyingGeneratedBinaryOperator(
        _ op: String, rhs: Any
    ) -> Any?
}

func generatedBinaryOperatorCombination(
    _ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue
) -> RuntimeValue? {
    guard case .host(let left) = lhs,
          let carrier = left as? GeneratedBinaryOperatorCarrier,
          case .host(let right) = rhs,
          let result = carrier.applyingGeneratedBinaryOperator(
            op, rhs: right) else {
        return nil
    }
    return .native(result)
}

extension GeneratedMemberCarrier {
    func writeGeneratedMemberValue(_ value: Any) -> Bool { false }
    func replacingGeneratedMemberValue(_ value: Any) -> Any? { nil }
}

extension Coerce {
    /// Foundation's unit system: `.fahrenheit`-style implicit members
    /// resolve through the swept Dimension statics (unique bare names —
    /// ambiguity throws, listing the candidate containers); qualified
    /// spellings arrive as host values and pass through.
    static func dimension(_ value: RuntimeValue) throws -> Dimension {
        if case .host(let any) = value {
            if let dimension = any as? Dimension { return dimension }
            if let platform = any as? GeneratedPlatformValue,
               let dimension = platform.payload as? Dimension {
                return dimension
            }
        }
        if let carrier = value.hostPayload as? Dimension { return carrier }
        if case .implicitMember(let name) = value {
            let containers = GeneratedMembers.dimensionContainersByBareName[name] ?? []
            if containers.count == 1,
               let unit = GeneratedMembers.dimensionStatics["\(containers[0]).\(name)"] {
                return unit
            }
            if containers.count > 1 {
                throw RuntimeError(message:
                    "unit .\(name) is ambiguous across \(containers.joined(separator: ", ")) — spell the container")
            }
        }
        // `UnitTemperature.fahrenheit` chained member (host type marker).
        if case .host(let any) = value, let chain = any as? ChainedImplicitCall,
           case .implicitMember(let container) = chain.base,
           let unit = GeneratedMembers.dimensionStatics["\(container).\(chain.member)"] {
            return unit
        }
        throw RuntimeError(message: "expected a Foundation unit (Dimension) like .fahrenheit")
    }
}
