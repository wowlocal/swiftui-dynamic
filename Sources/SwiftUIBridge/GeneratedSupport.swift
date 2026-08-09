import CoreTransferable
import Foundation
import SwiftUI
import SwiftInterpreter
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
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
    /// A parameter the interface declares as a localization key
    /// (`LocalizedStringKey`, `LocalizedStringResource`). It carries the same
    /// runtime `String` as `.string` and converts identically; what the tag
    /// adds is that a literal argument bound here is READ as a key, so its
    /// interpolations format under the current locale. The distinction is not
    /// expressible on the value — both overloads receive the same `String` —
    /// so it is the declared parameter type that selects the reading.
    case localizationKey
    /// A homogeneous collection whose element adapter and contextual type are
    /// both derived from the parameter's interface type.
    indirect case array(ParamTag, String)
    case color, font, fontWeight, angle, animation
    case alignment, horizontalAlignment, verticalAlignment, textAlignment
    case edgeSet, unitPoint, contentMode, imageScale, buttonRole
    case symbolRenderingMode
    case bindingBool, bindingString, bindingDouble
    /// `Binding<Value>` for any other `Value` the interface declares and this
    /// table already maps. The associated values are the coercion the VALUE
    /// resolves through and that value type's normalized name, which selects
    /// the generated adapter able to spell `Binding<Value>` concretely.
    ///
    /// The three cases above stay hand-written because each carries a value
    /// CONVERSION rather than a value: an `Int` state drives a `Double`
    /// slider, and a tagged selection reads back as the runtime value its
    /// `.tag(_:)` registered. This case converts nothing — it carries the
    /// value type's own coercion in both directions, which is why one case
    /// covers every remaining instantiation instead of one case per type.
    indirect case bindingValue(ParamTag, String)
    /// `Binding<(some Hashable)?>` — the selection-shaped binding a modifier
    /// declares when the value it tracks is "one of the identified items, or
    /// none". Carried by the same `InterpretedHashableValue` the wrapper
    /// projections use, so a selection written by the framework reads back
    /// through the interpreted binding unchanged.
    case bindingHashableOptional
    /// A projection of an SDK property wrapper that the interface declares
    /// with no public initializer, so no argument coercion can produce one
    /// (`FocusState<Value>.Binding`). The associated values are the enclosing
    /// wrapper's base name and whether its value is the interface's
    /// optional-Hashable shape; a generated carrier declares that wrapper and
    /// bridges it to the ordinary binding this tag coerces.
    case wrapperProjection(String, Bool)
    case shapeStyle, genericShapeStyle, anyView, shape
    /// A public, non-generic native value declared by SwiftUI's interfaces.
    case nativeSwiftUIValue(String)
    case visibility, axisSet, edgeInsets, gradient, gridItems
    case axis
    case dimension, measurement
    case builder
    /// Interface-declared non-View result builder and the protocol its
    /// closure result satisfies. Generated typed carriers consume this
    /// descriptor after overload selection.
    case resultBuilder(String, String)
    case action, asyncAction
    case syncVoidClosure
    /// A framework-owned synchronous callback whose declared result is a
    /// value rather than `Void`. The associated values are how many inputs
    /// the SDK supplies and the coercion its result resolves through — the
    /// same vocabulary a parameter of that type would use, so a callback
    /// returning a newly bridged type needs no new tag here.
    indirect case syncClosure(inputs: Int, result: ParamTag)
    /// A callback whose framework-supplied inputs are the same interface
    /// generic as an Equatable argument in the enclosing declaration.
    case equatableAction1, equatableAction2, equatable
    /// The same carrier one refinement up: an interface generic constrained
    /// only to Hashable (`matchedTransitionSource(id: some Hashable, …)`).
    case hashable
    /// An interface generic constrained only to Transferable
    /// (`draggable(_: some Transferable)`, `copyable`, `ShareLink(item:)`).
    case transferable
    // Foundation-value tags for the generated-members tier.
    case date, url, data, stringArray
    case decimal, characterSet, indexSet, dateComponents, dateInterval
    case indexPath, intArray, intRange, doubleRange
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

extension ParamTag {
    /// Whether an interpreted closure is what this parameter coerces, which
    /// is also what lets an unlabelled trailing argument bind to it. Asked of
    /// the tag rather than enumerated at each use, so a callback shape added
    /// later cannot be bridged and then silently miss trailing-closure
    /// syntax.
    var bindsAnInterpretedClosure: Bool {
        switch self {
        case .builder, .resultBuilder,
             .action, .asyncAction,
             .syncVoidClosure, .syncClosure,
             .equatableAction1, .equatableAction2:
            return true
        default:
            return false
        }
    }
}

/// Reify interpreter collection syntax as the concrete stdlib shape selected
/// by a generated conditional-conformance witness. BridgeGen supplies the
/// element coercion and type from swiftinterface metadata; these helpers know
/// only the runtime's structural array/range planes.
@MainActor
func generatedStructuralArray<Element>(
    _ value: RuntimeValue,
    elementTag: ParamTag,
    elementType: String,
    as: Element.Type,
    context: EvalContext
) throws -> [Element]? {
    guard let elements = value.arrayValue else { return nil }
    return try elements.map { element in
        guard let typed = try GeneratedDispatch.coerce(
            elementTag, element, context, contextualType: elementType
        ) as? Element else {
            throw RuntimeError(message: "generated structural element type mismatch")
        }
        return typed
    }
}

@MainActor
func generatedStructuralArraySlice<Element>(
    _ value: RuntimeValue,
    elementTag: ParamTag,
    elementType: String,
    as: Element.Type,
    context: EvalContext
) throws -> ArraySlice<Element>? {
    try generatedStructuralArray(
        value, elementTag: elementTag, elementType: elementType,
        as: Element.self, context: context
    ).map(ArraySlice.init)
}

@MainActor
func generatedStructuralRange<Bound: Comparable>(
    _ value: RuntimeValue,
    elementTag: ParamTag,
    elementType: String,
    as: Bound.Type,
    context: EvalContext
) throws -> Range<Bound>? {
    if case .host(let payload) = value {
        if let direct = payload as? Range<Bound> { return direct }
        if let carrier = payload as? GeneratedMemberCarrier,
           let unwrapped = carrier.generatedMemberValue as? Range<Bound> {
            return unwrapped
        }
    }
    guard let range = value.rangeValue,
          !range.includesUpperBound,
          let lowerValue = range.lowerBound,
          let upperValue = range.upperBound,
          let lower = try GeneratedDispatch.coerce(
            elementTag, lowerValue, context,
            contextualType: elementType) as? Bound,
          let upper = try GeneratedDispatch.coerce(
            elementTag, upperValue, context,
            contextualType: elementType) as? Bound else {
        return nil
    }
    return lower..<upper
}

@MainActor
func generatedStructuralClosedRange<Bound: Comparable>(
    _ value: RuntimeValue,
    elementTag: ParamTag,
    elementType: String,
    as: Bound.Type,
    context: EvalContext
) throws -> ClosedRange<Bound>? {
    if case .host(let payload) = value {
        if let direct = payload as? ClosedRange<Bound> { return direct }
        if let carrier = payload as? GeneratedMemberCarrier,
           let unwrapped = carrier.generatedMemberValue
                as? ClosedRange<Bound> {
            return unwrapped
        }
    }
    guard let range = value.rangeValue,
          range.includesUpperBound,
          let lowerValue = range.lowerBound,
          let upperValue = range.upperBound,
          let lower = try GeneratedDispatch.coerce(
            elementTag, lowerValue, context,
            contextualType: elementType) as? Bound,
          let upper = try GeneratedDispatch.coerce(
            elementTag, upperValue, context,
            contextualType: elementType) as? Bound else {
        return nil
    }
    return lower...upper
}

struct ParamSpec {
    let label: String?
    let tag: ParamTag
    let hasDefault: Bool
    /// The swiftinterface declared `Wrapped?`. The tag describes `Wrapped`;
    /// matching preserves an explicit nil and generated static code restores
    /// the concrete Optional type at the native call boundary.
    let isOptional: Bool
    /// Concrete parameter type read from the SDK interface. Source-declared
    /// extensions can add leading-dot static members to imported types, so
    /// coercion must resolve those members before applying the host adapter.
    let contextualType: String?

    init(
        _ label: String?, _ tag: ParamTag, hasDefault: Bool = false,
        isOptional: Bool = false, contextualType: String? = nil
    ) {
        self.label = label
        self.tag = tag
        self.hasDefault = hasDefault
        self.isOptional = isOptional
        self.contextualType = contextualType
    }
}

/// Interface-derived native writes for standard EnvironmentValues. Source
/// key paths are textual until this final boundary; generated closures restore
/// the concrete WritableKeyPath and value type declared by the SDK.
enum GeneratedEnvironmentValues {
    typealias Writer = @MainActor (
        AnyView, RuntimeValue, EvalContext
    ) throws -> AnyView

    struct Descriptor {
        let declaration: String
        let valueType: String
        let keyPathType: String
        let isOptional: Bool
        let coercionTag: String
        let writer: Writer
    }

    static let descriptors = build()

    static func apply(
        to view: AnyView, keyPath: KeyPathStub, value: RuntimeValue,
        context: EvalContext
    ) throws -> AnyView? {
        guard keyPath.components.count == 1,
              let component = keyPath.components.first,
              let descriptor = descriptors[component] else { return nil }
        return try descriptor.writer(view, value, context)
    }
}

/// Type-neutral absence carried through `[Any]` between generated overload
/// matching and a statically typed SDK invocation.
private struct GeneratedNilOptionalArgument {}

/// Restore the concrete Optional type inferred by the generated native call.
/// The transform is emitted from the wrapped swiftinterface type mapping, so
/// one adapter serves every concrete optional parameter without a type/API
/// allowlist.
nonisolated func generatedOptionalArgument<T>(
    _ value: Any, transform: (Any) -> T
) -> T? {
    guard !(value is GeneratedNilOptionalArgument) else { return nil }
    return transform(value)
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

/// One concrete specialization for an interface generic constrained only to
/// Equatable. Unlike the former textual surrogate, this carrier retains the
/// exact runtime payload so a correlated callback can hand framework-supplied
/// old/new values back to interpreted source without changing their type.
struct InterpretedEquatableValue: @unchecked Sendable, Equatable {
    let runtimeValue: RuntimeValue

    nonisolated static func == (
        lhs: InterpretedEquatableValue,
        rhs: InterpretedEquatableValue
    ) -> Bool {
        MainActor.assumeIsolated {
            (try? Builtins.equalValues(
                lhs.runtimeValue, rhs.runtimeValue)) ?? false
        }
    }
}

/// One concrete specialization for an interface generic constrained only to
/// Hashable, refining the Equatable carrier exactly as the protocol does: the
/// same retained payload, the same equality, plus a hash.
///
/// The hash combines nothing, and that is a correctness choice rather than a
/// shortcut. Equality here is the INTERPRETER's, which equates values across
/// representations a Swift `Hashable` synthesis would keep apart, so any hash
/// derived from one representation could disagree with `==` and silently lose
/// a key. A constant hash is the only one provably consistent with an equality
/// this carrier does not own; these values reach SwiftUI identity slots
/// holding a handful of entries, where bucket distribution costs nothing.
struct InterpretedHashableValue: @unchecked Sendable, Hashable {
    let runtimeValue: RuntimeValue

    nonisolated static func == (
        lhs: InterpretedHashableValue,
        rhs: InterpretedHashableValue
    ) -> Bool {
        MainActor.assumeIsolated {
            (try? Builtins.equalValues(
                lhs.runtimeValue, rhs.runtimeValue)) ?? false
        }
    }

    nonisolated func hash(into hasher: inout Hasher) {}
}

/// A property-wrapper projection the SDK declares with NO public initializer.
///
/// `FocusState<Value>.Binding` and `AccessibilityFocusState<Value>.Binding` are
/// each `@propertyWrapper struct Binding { private var _binding; var
/// wrappedValue; var projectedValue }` — every stored member private, and not
/// one initializer in the interface. So unlike every other parameter the
/// bridge coerces, this one admits no conversion at all: no value can be cast,
/// constructed, or adapted into the projection. It exists ONLY where the
/// enclosing wrapper is declared on a real view, as what SwiftUI hands back
/// from `$focus`.
///
/// That makes the whole family unbridgeable by argument coercion, which is the
/// property these carriers dispatch on rather than the name of any modifier:
/// the fix restructures the RECEIVER instead of converting the argument. The
/// carrier declares the real wrapper, hands the modifier SwiftUI's own
/// projection, and keeps the ordinary interpreted binding and the wrapper's
/// value in sync in both directions — so interpreted `@FocusState` state still
/// drives, and observes, native focus.
///
/// The carriers themselves are GENERATED, one pair per wrapper the scan finds
/// (`Sources/SwiftUIBridge/Generated/GeneratedWrapperProjections.swift`): the
/// pair is a Bool carrier and an optional-Hashable one, because those are the
/// two initializers the interface declares — `init() where Value == Bool` and
/// `init<T>() where Value == T?, T: Hashable`. `FocusState<Value>` is not
/// constructible for a bare generic `Value: Hashable`, so the split follows
/// what the interface permits rather than what would be tidier.

/// One concrete specialization for an interface generic constrained only to
/// Transferable, in the same shape as the Equatable/Hashable carriers above:
/// the interpreted payload is retained, and the protocol is answered on its
/// behalf rather than by narrowing the generic to one concrete conformer.
///
/// `Transferable`'s requirement is STATIC (`static var transferRepresentation`),
/// so one carrier type gets one representation list for every payload it will
/// ever hold — it cannot ask the instance what content type it declares. What
/// it can do is condition each representation on the instance, which is what
/// `exportingCondition` is for, so the list below offers exactly the host
/// representations the payload already has.
///
/// A payload the source program declares `: Transferable` itself is retained
/// and rendered, but exports nothing yet: reading its own
/// `transferRepresentation` means evaluating a `TransferRepresentationBuilder`
/// tower, and `TransferRepresentation` has an associated `Item` type, which is
/// the same wall that keeps `Tab`/`TabContent` out of the generated carrier
/// tier. Offering no representation is the truthful answer to "what can this
/// value become"; inventing a content type it never declared would not be.
struct InterpretedTransferableValue: @unchecked Sendable, Transferable {
    /// What the payload already means to the system's transfer machinery.
    enum Payload: Sendable {
        case url(URL)
        case string(String)
        case data(Data)
        /// A conformance declared by interpreted source, whose representation
        /// the bridge cannot evaluate yet.
        case sourceDeclared
    }

    let runtimeValue: RuntimeValue
    let payload: Payload

    @MainActor init(_ value: RuntimeValue, context: EvalContext) throws {
        runtimeValue = value
        if let url = value.hostPayload as? URL {
            payload = .url(url)
        } else if let data = value.hostPayload as? Data {
            payload = .data(data)
        } else if let string = value.stringValue {
            payload = .string(string)
        } else if context.hostValue(value, conformsTo: "Transferable") {
            payload = .sourceDeclared
        } else {
            throw RuntimeError(message: "expected a Transferable value")
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (value: InterpretedTransferableValue) -> URL in
            guard case .url(let url) = value.payload else {
                throw RuntimeError(message: "payload is not a URL")
            }
            return url
        }
        .exportingCondition { value in
            if case .url = value.payload { true } else { false }
        }

        ProxyRepresentation { (value: InterpretedTransferableValue) -> Data in
            guard case .data(let data) = value.payload else {
                throw RuntimeError(message: "payload is not Data")
            }
            return data
        }
        .exportingCondition { value in
            if case .data = value.payload { true } else { false }
        }

        ProxyRepresentation { (value: InterpretedTransferableValue) -> String in
            guard case .string(let string) = value.payload else {
                throw RuntimeError(message: "payload is not a String")
            }
            return string
        }
        .exportingCondition { value in
            if case .string = value.payload { true } else { false }
        }
    }
}

/// Generated correlated-generic callbacks use the same closure/context
/// carrier regardless of callback arity. The swiftinterface determines both
/// the arity and where the shared Equatable generic appears.
struct EquatableActionValue: @unchecked Sendable {
    let closure: ClosureValue
    let context: EvalContext

    @MainActor
    func call(_ arguments: [InterpretedEquatableValue]) {
        InterpretedHostCallback(
            closure: closure,
            context: context,
            diagnosticContext: "generated Equatable action"
        ).call(arguments: arguments.map(\.runtimeValue))
    }
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

    @MainActor
    func call(arguments: [RuntimeValue]) throws -> RuntimeValue {
        try context.callHostCallback(closure, arguments: arguments)
    }
}

/// `ViewDimensions` is intentionally non-Sendable even though SwiftUI's
/// callback is `@Sendable`. The callback is synchronous and main-thread-only;
/// erase its argument before the checked actor hop and carry that immutable
/// runtime value through an explicitly unchecked box.
private struct SyncClosureRuntimeArgument: @unchecked Sendable {
    let value: RuntimeValue
}

private struct SyncClosureRuntimeArguments: @unchecked Sendable {
    let values: [RuntimeValue]
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
    /// Concrete result promised by an interface-declared static factory.
    /// Initializers may leave this nil because their lookup key already names
    /// the nominal; factories on a generic nominal share a base key and need
    /// the specialized result to preserve contextual generic inference.
    let declaredResultType: String?
    let invoke: @MainActor ([Any]) throws -> Any

    init(
        params: [ParamSpec],
        isDisfavored: Bool = false,
        declaredResultType: String? = nil,
        invoke: @escaping @MainActor ([Any]) throws -> Any
    ) {
        self.params = params
        self.isDisfavored = isDisfavored
        self.declaredResultType = declaredResultType
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

    /// A generic nominal's same-type statics are registered under its base
    /// name (`Wrapper.member`) because that is the explicit source spelling.
    /// When the call is contextual, however, `Wrapper<Int>` must see only
    /// factories whose interface result is `Wrapper<Int>`. Filtering on the
    /// declared result restores that language rule without knowing any SDK
    /// type or member identity.
    func constrained(toResultType expected: String) -> GeneratedConstructorSet? {
        let matching = byArity.values.flatMap { overloads in
            overloads.filter { overload in
                guard let declared = overload.declaredResultType else {
                    return false
                }
                return HostSignature.equivalentTypeName(declared, expected)
            }
        }
        return matching.isEmpty ? nil : GeneratedConstructorSet(matching)
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
    /// A generated contextual factory has already produced the exact native
    /// type promised by the parameter's interface contract. Accept that value
    /// before tag-specific source coercions inspect literal syntax (for
    /// example `.degrees(45)` becomes a real Angle, not an implicit call).
    private static func nativeValue(
        _ value: RuntimeValue, matching typeName: String
    ) -> Any? {
        guard let payload = value.hostPayload else { return nil }
        let native = (payload as? GeneratedMemberCarrier)?
            .generatedMemberValue ?? payload
        guard GeneratedMembers.keyTypeName(of: native) == typeName
                || GeneratedMembers.declarationPath(of: native) == typeName
                || GeneratedPlatformBridge.directRuntimeTypeName(
                    of: native
                ).map(GeneratedPlatformBridge.canonicalTypeName)
                    == GeneratedPlatformBridge.canonicalTypeName(typeName)
        else { return nil }
        return native
    }

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
            apply: { value, rawArgs, ctx in
                // Both branches below see the interface's reading of the call,
                // so a handwritten body inherits it without naming the rule.
                let args = readingLocalizationKeys(
                    rawArgs, modifier: name, ctx: ctx)
                // An adapter that covers a SUBSET of the name hands the rest
                // back: those overloads are ordinary interface API and the
                // generated tier already spells them. Without this the
                // handwritten body sees arguments it has no case for and
                // returns the receiver, so the modifier silently does nothing.
                //
                // Only when that tier actually has a fitting overload, though.
                // A declined call no tier can serve stays with the adapter it
                // has always had, so this can add reach and never remove it.
                if !modifier.ownsCall(args, in: ctx),
                   serves(overloads: overloads, args: args, ctx: ctx) {
                    let view = try ViewRegistry.anyView(value)
                    return .native(try dispatch(
                        name: name, overloads: overloads, view: view,
                        args: args, ctx: ctx))
                }
                return try modifier.apply(value, args, ctx)
            })
    }

    static func coerce(
        _ tag: ParamTag, _ unresolvedValue: RuntimeValue,
        _ ctx: EvalContext, contextualType: String? = nil
    ) throws -> Any {
        let value = contextualType.map {
            ctx.resolveForBridge(unresolvedValue, typeName: $0)
        } ?? unresolvedValue
        if let contextualType,
           let native = nativeValue(value, matching: contextualType) {
            return native
        }
        switch tag {
        case .string, .localizationKey:
            guard let s = value.stringValue else { throw RuntimeError(message: "expected a String") }
            return s
        case .array(let elementTag, let elementType):
            guard let elements = value.collectionElements else {
                throw RuntimeError(message: "expected a collection")
            }
            return try elements.map {
                try coerce(
                    elementTag, $0, ctx, contextualType: elementType)
            }
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
        case .bindingBool:
            return try Coerce.boolBinding(value, context: ctx)
        case .wrapperProjection(_, let isOptionalValue):
            // The projection itself is not constructible; what crosses here is
            // the ordinary binding the generated carrier will drive it from.
            return isOptionalValue
                ? try Coerce.hashableOptionalBinding(value, context: ctx)
                : try Coerce.boolBinding(value, context: ctx)
        case .bindingHashableOptional:
            return try Coerce.hashableOptionalBinding(value, context: ctx)
        case .bindingString:
            return try Coerce.stringBinding(value, context: ctx)
        case .bindingDouble:
            return try Coerce.doubleBinding(value, context: ctx)
        case .bindingValue(let valueTag, let valueTypeName):
            let box = try Coerce.bindingBox(value, context: ctx)
            // The storage's CURRENT value has to coerce, and that is what
            // makes the parameter matchable-or-not by exactly the rule an
            // ordinary argument is matched by: a binding over a `Date` does
            // not satisfy `Binding<Color>`, so the overload it belongs to is
            // not selected. Nothing here inspects the value's identity — the
            // value type's own coercion answers, whatever it is.
            let seed = try coerce(valueTag, box.value, ctx)
            guard let adapter =
                    GeneratedBindingValues.adapters[valueTypeName],
                  let binding = adapter(
                    seed,
                    InterpretedBindingStorage(
                        read: { try? coerce(valueTag, box.value, ctx) },
                        write: { box.value = .native($0) }))
            else {
                throw RuntimeError(message:
                    "expected a binding to a \(valueTypeName)")
            }
            return binding
        case .shapeStyle:
            return try Coerce.shapeStyle(value)
        case .genericShapeStyle:
            return try Coerce.genericShapeStyle(value)
        case .anyView:
            return try ViewRegistry.anyView(value, resolving: ctx)
        case .nativeSwiftUIValue(let typeName):
            if let native = nativeValue(value, matching: typeName) {
                return native
            }
            if let structural =
                    GeneratedMembers.structuralValueCoercions[typeName] {
                return try structural(value, ctx)
            }
            throw RuntimeError(message:
                "expected a native SwiftUI \(typeName) value")
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
        case .resultBuilder:
            guard value.closureValue != nil else {
                throw RuntimeError(message: "expected a result-builder closure")
            }
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
        case .syncVoidClosure, .syncClosure:
            guard let closure = value.closureValue else {
                throw RuntimeError(message: "expected a synchronous closure")
            }
            return SyncClosureValue(closure: closure, context: ctx)
        case .equatableAction1, .equatableAction2:
            guard let closure = value.closureValue else {
                throw RuntimeError(message:
                    "expected an Equatable-correlated closure")
            }
            return EquatableActionValue(closure: closure, context: ctx)
        case .equatable:
            return InterpretedEquatableValue(runtimeValue: value)
        case .hashable:
            return InterpretedHashableValue(runtimeValue: value)
        case .transferable:
            return try InterpretedTransferableValue(value, context: ctx)
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
        case .dimension:
            return try Coerce.dimension(value)
        case .measurement:
            if case .host(let any) = value, let measurement = any as? Measurement<Dimension> {
                return measurement
            }
            if let carrier = value.hostPayload as? Measurement<Dimension> { return carrier }
            throw RuntimeError(message: "expected a Measurement value")
        case .sdkEnum(let typeName):
            return try GeneratedSDKEnumCoercions.coerce(
                typeName, value, context: ctx)
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
            guard argument.label == param.label
                || (argument.isTrailing && argument.label == nil
                    && param.tag.bindsAnInterpretedClosure)
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
            let sourceValue: RuntimeValue
            if param.isOptional {
                guard let wrapped =
                        argument.value.unwrappedOptionalOrSelf else {
                    values.append(GeneratedNilOptionalArgument())
                    continue
                }
                sourceValue = wrapped
            } else {
                sourceValue = argument.value
            }
            guard let coerced = try? coerce(
                    param.tag, sourceValue, ctx,
                    contextualType: param.contextualType) else { return nil }
            values.append(coerced)
        }
        return values
    }

    /// Prefer an interface result-builder overload only when declaration
    /// metadata proves the closure's branch result types conform to its
    /// protocol. This is the runtime analogue of the compiler's generic
    /// result constraint and avoids resolving same-shaped builders by table
    /// order or by speculatively executing their bodies.
    private static func provesResultBuilder(
        _ params: [ParamSpec],
        _ args: CallArguments,
        _ ctx: EvalContext
    ) -> Bool {
        guard labelsMatch(params, args) else { return false }
        return zip(params, args.arguments).contains {
            parameter, argument in
            guard case .resultBuilder(_, let resultProtocol) =
                    parameter.tag,
                  let closure = argument.value.closureValue else {
                return false
            }
            return ctx.resultBuilderClosure(
                closure,
                matchesResultProtocol: resultProtocol) == true
        }
    }

    /// Same coercion boundary used by generated modifiers, exposed to the
    /// generated contextual-value tier for fluent same-type SDK methods
    /// (`.member.transform(...)`). BridgeGen supplies both the method shape
    /// and each contextual parameter type from the swiftinterface.
    static func contextualMethodArguments(
        _ params: [ParamSpec], _ args: CallArguments, _ ctx: EvalContext
    ) -> [Any]? {
        matches(params, args, ctx)
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

    /// Argument positions this call binds to a parameter the SDK interface
    /// declares as a localization key.
    ///
    /// A position counts when ANY overload whose labels and arity fit the call
    /// declares it as a key — which is the compiler's own choice between the
    /// two overloads SwiftUI publishes for the same call (`Text(_:
    /// LocalizedStringKey)` beside `Text(_: some StringProtocol)`, and the same
    /// pair at `Button`, `Label`, `Toggle`, `.navigationTitle`): a literal
    /// selects the key one. The reading only ever applies to an argument that
    /// WAS spelled as a literal, so a call with a `String`-typed expression is
    /// untouched no matter which overloads exist.
    private static func localizationKeyPositions(
        _ shapes: [[ParamSpec]], _ args: CallArguments
    ) -> Set<Int> {
        var positions: Set<Int> = []
        for params in shapes where labelsMatch(params, args) {
            for (index, param) in params.enumerated()
            where param.tag == .localizationKey {
                positions.insert(index)
            }
        }
        return positions
    }

    /// The call as its interface-declared localization-key parameters read it.
    ///
    /// Applied once per tier boundary rather than per API, so a gateway that is
    /// still handwritten for interface-inexpressible reasons (`Button`'s
    /// result-builder label, `Toggle`'s binding) gets the same reading as a
    /// generated one without knowing the rule exists.
    ///
    /// Bounded: the literal is carried per ARGUMENT, so an array of keys
    /// (`accessibilityInputLabels`) has no per-element reading and stays
    /// verbatim.
    static func readingLocalizationKeys(
        _ args: CallArguments, modifier name: String, ctx: EvalContext
    ) -> CallArguments {
        guard let overloads = GeneratedModifiers.table[name] else { return args }
        return args.readingLocalizationKeys(
            at: localizationKeyPositions(
                (overloads.byArity[args.arguments.count] ?? []).map(\.params),
                args),
            resolveStyle: styleResolver(ctx))
    }

    static func readingLocalizationKeys(
        _ args: CallArguments, constructor overloads: GeneratedConstructorSet?,
        ctx: EvalContext
    ) -> CallArguments {
        guard let overloads else { return args }
        return args.readingLocalizationKeys(
            at: localizationKeyPositions(
                (overloads.byArity[args.arguments.count] ?? []).map(\.params),
                args),
            resolveStyle: styleResolver(ctx))
    }

    /// The one place a format style carried by a localization key becomes
    /// text, shared by every reading above so a modifier, a constructor and
    /// the handwritten `Text` gateway cannot disagree about the same literal.
    ///
    /// The resolver crosses into SwiftInterpreter, which is deliberately
    /// executor-neutral, so it cannot carry this module's MainActor default
    /// in its type. The isolation is real rather than assumed away: `ctx` is
    /// an `EvalContext`, a `@MainActor` protocol, so holding one already
    /// means running on the main actor and the resolver is only ever called
    /// synchronously beneath that call.
    static func styleResolver(
        _ ctx: EvalContext
    ) -> (RuntimeValue, RuntimeValue) -> String? {
        { value, style in
            MainActor.assumeIsolated {
                LocalizedFormatStyleRendering.text(value, style: style, ctx)
            }
        }
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

    /// The overload this call resolves to, and the arguments coerced for it.
    /// Selection only — nothing is invoked, so asking whether the generated
    /// tier serves a call costs exactly what dispatching it would decide.
    private static func resolvedOverload(
        overloads: GeneratedOverloadSet,
        args: CallArguments,
        ctx: EvalContext
    ) -> (overload: GeneratedOverload, values: [Any])? {
        let candidates = overloads.byArity[args.arguments.count] ?? []
        for overload in candidates where provesResultBuilder(
            overload.params, args, ctx) {
            guard isAvailable(overload, in: ctx) else { continue }
            guard let values = matches(overload.params, args, ctx) else { continue }
            return (overload, values)
        }
        for overload in candidates where !provesResultBuilder(
            overload.params, args, ctx) {
            guard isAvailable(overload, in: ctx) else { continue }
            guard let values = matches(overload.params, args, ctx) else {
                continue
            }
            return (overload, values)
        }
        return nil
    }

    /// Whether the interface tier has an overload that fits this call. Shares
    /// `resolvedOverload` with `dispatch`, so the answer and the dispatch
    /// cannot disagree.
    static func serves(
        overloads: GeneratedOverloadSet,
        args: CallArguments,
        ctx: EvalContext
    ) -> Bool {
        resolvedOverload(overloads: overloads, args: args, ctx: ctx) != nil
    }

    static func dispatch(
        name: String,
        overloads: GeneratedOverloadSet,
        view: AnyView,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> AnyView {
        guard let (overload, values) = resolvedOverload(
            overloads: overloads, args: args, ctx: ctx) else {
            let shape = args.arguments.map { $0.label ?? "_" }.joined(separator: ":")
            throw RuntimeError(message: "no matching overload for .\(name)(\(shape):) — argument types or labels don't fit")
        }
        let native = try overload.invoke(view, values)
        guard let adapter = overload.semanticAdapter else {
            return native
        }
        return adapter.apply(
            to: native, receiver: view, values: values, context: ctx)
    }

    static func construct(
        name: String,
        overloads: GeneratedConstructorSet,
        args: CallArguments,
        ctx: EvalContext
    ) throws -> Any {
        let candidates = overloads.byArity[args.arguments.count] ?? []
        for overload in candidates where provesResultBuilder(
            overload.params, args, ctx) {
            guard let values = matches(overload.params, args, ctx) else {
                continue
            }
            return try overload.invoke(values)
        }
        for overload in candidates where !provesResultBuilder(
            overload.params, args, ctx) {
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
    typealias StructuralValueCoercion = @MainActor (
        RuntimeValue, EvalContext
    ) throws -> Any

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

    /// The path a consuming interface declaration spells this value's type
    /// with. `String(describing:)` prints a nested nominal's LEAF, and leaves
    /// collide — seven SwiftUI nominals declare a nested `ID`, so the printed
    /// name cannot answer which type a value is. The runtime's own qualified
    /// name carries the full nesting; drop the module it was declared in and
    /// what remains is the interface's spelling (`Namespace.ID`, `Color`).
    static func declarationPath(of value: Any) -> String {
        let reflected = String(reflecting: type(of: value))
        guard let separator = reflected.firstIndex(of: "."),
              !reflected[..<separator].contains("<") else { return reflected }
        return String(reflected[reflected.index(after: separator)...])
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
    let direct = GeneratedMembers.nativeValueConstructors[name]
    // The interpreter resolves `Generic<Value>` in two language steps: the
    // base nominal asks the registry for its constructor, then generic
    // specialization supplies `Value` as a hidden argument. Generated native
    // value constructors are intentionally keyed by the concrete interface
    // type, so let any base with concrete generated instantiations claim that
    // first step. Invocation below resolves the second one exactly.
    let genericInstantiations = GeneratedMembers.nativeValueConstructors.keys
        .filter { typeName in
            guard let open = typeName.firstIndex(of: "<") else { return false }
            return String(typeName[..<open]) == name
        }
        .sorted()
    guard direct != nil || !genericInstantiations.isEmpty else {
        return nil
    }
    return HostFunction(name: name) { arguments, context in
        let overloads: GeneratedConstructorSet
        if let genericArguments = arguments
            .labeled("__genericArguments")?.stringValue {
            let expected = "\(name)<\(genericArguments)>"
            let candidates = genericInstantiations.filter {
                HostSignature.equivalentTypeName($0, expected)
            }
            guard candidates.count == 1,
                  let specialized = candidates.first.flatMap({
                      GeneratedMembers.nativeValueConstructors[$0]
                  }) else {
                throw RuntimeError(message:
                    "no unique generated native constructor for \(expected)")
            }
            overloads = specialized
        } else if let direct {
            overloads = direct
        } else {
            throw RuntimeError(message:
                "generic native constructor '\(name)' needs concrete type arguments")
        }
        let sourceArguments = CallArguments(
            arguments: arguments.arguments.filter {
                $0.label != "__genericArguments"
            },
            sourceSiteID: arguments.sourceSiteID)
        return .native(try GeneratedDispatch.construct(
            name: name,
            overloads: overloads,
            args: sourceArguments,
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
                        try coerce(
                            param.tag, argument.value, ctx,
                            contextualType: param.contextualType)
                    }
                    // EXPERIMENT (opt-in via BOUNDARY_JIT=1): service the call
                    // from a shim compiled off `overload.signature` instead of
                    // the hand-emitted `invoke` closure. Same receiver, same
                    // coerced `[Any]`, same RuntimeValue out.
                    if CompiledBoundary.isEnabled {
                        do {
                            return try CompiledBoundary.shared.invoke(
                                signature: overload.signature,
                                receiver: base,
                                arguments: values)
                        } catch {
                            CompiledBoundary.note(
                                declaration: overload.signature.declaration,
                                error: error)
                        }
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

/// The interpreted storage a `$x` projection names, seen without knowing what
/// it holds: read it already coerced to the host value type, write a host
/// value back. Both directions are the VALUE type's own coercion, supplied by
/// the caller, so this carries no knowledge of any particular type.
struct InterpretedBindingStorage {
    let read: () -> Any?
    let write: (Any) -> Void
}

/// The one primitive every generated `Binding<Value>` adapter is built from.
///
/// A `Binding<Value>` cannot be produced by converting an argument the way an
/// ordinary parameter is: an interpreted `$model.tint` is a projection onto
/// interpreted storage, so it is never a `Binding` SwiftUI itself built, and
/// asking whether it already IS one can only ever answer no. What it can be is
/// DRIVEN — which needs the concrete `Value` spelled somewhere real, and that
/// is what the generated table supplies.
enum GeneratedBindingValueSupport {
    /// Retains the last value that coerced, so the getter is total without
    /// inventing a default for `Value` — there is no interface fact that would
    /// say what a `Color`'s or a `ScrollPosition`'s stand-in should be. The
    /// seed is the value the storage held when the argument was matched, so a
    /// binding that matched always reads something the interpreted program
    /// actually wrote.
    private final class LastValue<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    static func binding<Value>(
        _ seed: Any,
        _ storage: InterpretedBindingStorage,
        as _: Value.Type
    ) -> Any? {
        guard let seed = seed as? Value else { return nil }
        let last = LastValue(seed)
        return Binding<Value>(
            get: {
                if let current = storage.read() as? Value {
                    last.value = current
                }
                return last.value
            },
            set: { storage.write($0) })
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

/// Namespace the generated framework-supplied property wrappers extend with
/// `build()`. `@Namespace var ns` hands the wrapper nothing and reads nothing
/// back but `wrappedValue`, so the value belongs to the framework, not to the
/// declaration — and there is no source expression to evaluate for it.
enum GeneratedPropertyWrappers {
    static let table: [String: @MainActor () -> Any] = build()

    /// The value a declaration annotated with these attributes stores. The
    /// attribute list comes from the source declaration, so a wrapper the
    /// interpreter models itself never reaches here.
    @MainActor
    static func suppliedValue(forAttributes attributes: [String]) -> Any? {
        for attribute in attributes {
            // `@SwiftUI.Namespace` names the same wrapper as `@Namespace`.
            let name = attribute.split(separator: ".").last.map(String.init)
                ?? attribute
            if let supply = table[name] { return supply() }
        }
        return nil
    }
}

/// Namespace the generated same-type static factories extend with `build()`.
///
/// These are the interface's second spelling of a nominal's own constructor —
/// a static whose declared result IS the enclosing type. They need generated
/// dispatch rather than the leading-dot marker path because a marker only
/// resolves against a parameter's expected type, and the positions these
/// reach (a View body, a `some View` result) declare none. Keys are
/// `Type.member`, so one table answers both the value spelling (`static var`,
/// arity zero) and the call spelling (`static func`).
enum GeneratedStaticFactories {
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
        resultType: String? = nil,
        _ invoke: @escaping @MainActor ([Any]) throws -> Any
    ) {
        table[name, default: []].append(GeneratedConstructor(
            params: params,
            isDisfavored: isDisfavored,
            declaredResultType: resultType,
            invoke: invoke))
    }

    static func key(_ member: String, onTypeNamed typeName: String) -> String {
        typeName + "." + member
    }

    /// Explicit source spells a generic static on the base nominal, while a
    /// leading-dot call arrives with the parameter's concrete instantiation.
    /// Look up the shared base table in the latter case and retain only the
    /// overloads whose interface-declared result is that instantiation.
    private static func overloads(
        _ member: String, onTypeNamed typeName: String
    ) -> GeneratedConstructorSet? {
        if let exact = table[key(member, onTypeNamed: typeName)] {
            return exact
        }
        guard let genericStart = typeName.firstIndex(of: "<") else {
            return nil
        }
        let base = String(typeName[..<genericStart])
        return table[key(member, onTypeNamed: base)]?
            .constrained(toResultType: typeName)
    }

    /// The VALUE spelling: `ContentUnavailableView.search`. Only the swept
    /// zero-parameter overload can answer a bare member read.
    @MainActor
    static func value(
        _ member: String, onTypeNamed typeName: String
    ) throws -> Any? {
        guard let overload = overloads(member, onTypeNamed: typeName)?
            .byArity[0]?.first else { return nil }
        return try overload.invoke([])
    }

    /// The CALL spelling: `ContentUnavailableView.search(text:)`. Overload
    /// selection is the generated constructor path, so labels and argument
    /// types are validated by the same interface-derived contracts.
    static func method(
        _ member: String, onTypeNamed typeName: String
    ) -> HostFunction? {
        let name = key(member, onTypeNamed: typeName)
        guard let overloads = overloads(member, onTypeNamed: typeName),
              overloads.byArity.keys.contains(where: { $0 > 0 }) else {
            return nil
        }
        return HostFunction(name: member) { args, ctx in
            .native(try GeneratedDispatch.construct(
                name: name, overloads: overloads, args: args, ctx: ctx))
        }
    }
}

/// Namespace extended by interface-generated non-View result-builder
/// carriers. The generated implementations retain native protocol values
/// without teaching handwritten dispatch about any SDK builder identity.
enum GeneratedResultBuilderCarriers {}

/// Namespace extended by methods whose protocol declares both an opaque
/// `some P` result and its native `@_typeEraser`. Generated dispatch applies
/// those methods to the erased receiver and immediately re-erases the result.
enum GeneratedOpaqueProtocolMembers {}

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
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
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

/// Reconstitute callback shapes whose inputs share the declaration's
/// Equatable generic. The generated native call supplies carrier values; the
/// wrapper returns their exact interpreted payloads to source.
nonisolated func generatedEquatableAction1(
    _ value: Any
) -> (InterpretedEquatableValue) -> Void {
    let action = value as! EquatableActionValue
    return { newValue in
        MainActor.assumeIsolated {
            action.call([newValue])
        }
    }
}

nonisolated func generatedEquatableAction2(
    _ value: Any
) -> (InterpretedEquatableValue, InterpretedEquatableValue) -> Void {
    let action = value as! EquatableActionValue
    return { oldValue, newValue in
        MainActor.assumeIsolated {
            action.call([oldValue, newValue])
        }
    }
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

/// The same boundary for a callback the SDK calls back FOR a value. The
/// interpreted result is coerced through the identical vocabulary a parameter
/// of that declared type would use, so no result type is named here and a
/// newly bridged one needs no new adapter.
///
/// `fallback` is reachable only when the interpreted callback itself failed —
/// it already recorded a diagnostic and no answer it could give is the right
/// one. BridgeGen supplies the value instead of this adapter choosing it, so
/// what a failed callback returns is visible in the emitted source rather
/// than hidden in a runtime default.
nonisolated func generatedSyncClosureResult<Produced: Sendable>(
    _ callback: SyncClosureValue,
    _ inputs: [RuntimeValue],
    _ result: ParamTag,
    _ contextualType: String?,
    _ fallback: Produced
) -> Produced {
    let arguments = SyncClosureRuntimeArguments(values: inputs)
    return MainActor.assumeIsolated {
        do {
            let produced = try callback.call(arguments: arguments.values)
            guard let coerced = try GeneratedDispatch.coerce(
                result, produced, callback.context,
                contextualType: contextualType) as? Produced
            else {
                throw RuntimeError(message:
                    "callback returned a value that is not the declared "
                        + (contextualType ?? "\(Produced.self)"))
            }
            return coerced
        } catch let error as RuntimeError {
            RenderDiagnostics.record(
                error, in: "generated synchronous callback result")
        } catch {
            RenderDiagnostics.record(
                RuntimeError(message: String(describing: error)),
                in: "generated synchronous callback result")
        }
        return fallback
    }
}

/// Arity is a structural property of the declared callback, so the two shapes
/// differ only in how many inputs they hand across — not in what they do.
nonisolated func generatedSyncClosure0<Produced: Sendable>(
    _ value: Any, result: ParamTag, contextualType: String?,
    fallback: Produced
) -> @Sendable () -> Produced {
    let callback = value as! SyncClosureValue
    return {
        generatedSyncClosureResult(
            callback, [], result, contextualType, fallback)
    }
}

nonisolated func generatedSyncClosure1<Input, Produced: Sendable>(
    _ value: Any, result: ParamTag, contextualType: String?,
    fallback: Produced
) -> @Sendable (Input) -> Produced {
    let callback = value as! SyncClosureValue
    return { input in
        generatedSyncClosureResult(
            callback, [.host(input)], result, contextualType, fallback)
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
