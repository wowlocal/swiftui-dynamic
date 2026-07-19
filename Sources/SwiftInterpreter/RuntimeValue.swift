import Foundation
import SwiftSyntax

/// `_openExistential` exposes an erased payload's dynamic type when an API has
/// explicitly requested Optional-preserving normalization. Keeping this probe
/// out of the ordinary `native(Any)` hot path is material for collection-heavy
/// interpretation.
private func runtimeValueIsOptional<T>(_ value: T) -> Bool {
    _isOptional(T.self)
}

/// The type-erased runtime representation of every value the interpreter touches.
///
/// Swift-language values live in dedicated cases so evaluator semantics never
/// depend on existential casts. `.host` is reserved for opaque framework and
/// embedder values such as `AnyView`, `Date`, and `URL`. User-defined values
/// are `.instance`; functions and closures are `.closure`; pre-compiled host
/// gateways are `.hostFunction`.
///
/// Construct through the `native(_:)` factories. The untyped overload
/// normalizes every supported core value into its dedicated case while
/// preserving the opaque host escape hatch at the framework boundary.
@MainActor
public enum RuntimeValue {
    case void
    case nilValue
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case array([RuntimeValue])
    case dictionary(DictValue)
    case tuple(TupleValue)
    indirect case range(RuntimeRangeValue)
    case host(Any)
    case instance(Instance)
    case closure(ClosureValue)
    case hostFunction(HostFunction)
    case type(StructSymbol)
    case enumType(EnumSymbol)
    case enumCase(EnumCaseValue)
    case implicitMember(String)
    /// Appended to preserve the tag layout of the established public cases
    /// for incrementally built embedders.
    case set(RuntimeSetValue)
    /// Appended for the same ABI-conscious reason. The immutable payload is
    /// reference-backed so nested optionals retain every source-level wrapper
    /// without making this hot enum case indirect.
    case optional(RuntimeOptionalValue)

    @inline(__always) public static func native(_ value: Int) -> RuntimeValue { .int(value) }
    @inline(__always) public static func native(_ value: Double) -> RuntimeValue { .double(value) }
    @inline(__always) public static func native(_ value: Bool) -> RuntimeValue { .bool(value) }
    @inline(__always) public static func native(_ value: String) -> RuntimeValue { .string(value) }
    @inline(__always) public static func native(_ value: [RuntimeValue]) -> RuntimeValue { .array(value) }
    @inline(__always) public static func native(_ value: RuntimeSetValue) -> RuntimeValue { .set(value) }
    @inline(__always) public static func native(_ value: DictValue) -> RuntimeValue { .dictionary(value) }
    @inline(__always) public static func native(_ value: TupleValue) -> RuntimeValue { .tuple(value) }
    @inline(__always) public static func native(_ value: RuntimeRangeValue) -> RuntimeValue { .range(value) }
    /// Preserve a statically known host Optional at the interpreter boundary.
    public static func native<Wrapped>(_ value: Wrapped?) -> RuntimeValue {
        let wrappedTypeName = String(describing: Wrapped.self)
        guard let value else { return .none(wrappedTypeName: wrappedTypeName) }
        let payload = _isOptional(Wrapped.self)
            ? nativePreservingOptional(value as Any)
            : native(value as Any)
        return .some(payload, wrappedTypeName: wrappedTypeName)
    }

    /// Normalize an explicitly erased boundary that may contain Optional.
    /// Ordinary statically typed Optionals should use `native(_ value: T?)`,
    /// which avoids this dynamic metadata query entirely.
    public static func nativePreservingOptional(_ value: Any) -> RuntimeValue {
        if _openExistential(value, do: runtimeValueIsOptional) {
            let mirror = Mirror(reflecting: value)
            let typeName = String(describing: Swift.type(of: value))
            let wrappedTypeName: String? = {
                guard typeName.hasPrefix("Optional<"), typeName.hasSuffix(">") else {
                    return nil
                }
                return String(typeName.dropFirst("Optional<".count).dropLast())
            }()
            guard let child = mirror.children.first else {
                return .none(wrappedTypeName: wrappedTypeName)
            }
            return .some(
                nativePreservingOptional(child.value),
                wrappedTypeName: wrappedTypeName)
        }
        return native(value)
    }

    /// The fast untyped fallback for values with no Optional static contract.
    /// Call `nativePreservingOptional` at an intentionally erased Optional
    /// boundary; probing every opaque host object here regresses collection
    /// workloads by an order of magnitude.
    public static func native(_ value: Any) -> RuntimeValue {
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let g = value as? CGFloat { return .double(Double(g)) }
        if let f = value as? Float { return .double(Double(f)) }
        if let b = value as? Bool { return .bool(b) }
        if let string = value as? String { return .string(string) }
        if let array = value as? [RuntimeValue] { return .array(array) }
        if let set = value as? RuntimeSetValue { return .set(set) }
        if let dictionary = value as? DictValue { return .dictionary(dictionary) }
        if let tuple = value as? TupleValue { return .tuple(tuple) }
        if let range = RuntimeRangeValue.fromNative(value) { return .range(range) }
        return .host(value)
    }
}

extension RuntimeValue {
    /// The payload as a host `Any` — inline scalars box on demand (member
    /// dispatch and gateway coercion want one uniform payload; arithmetic
    /// never calls this). Non-payload cases return nil.
    public var hostPayload: Any? {
        switch self {
        case .host(let any): return any
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .string(let string): return string
        case .array(let array): return array
        case .set(let set): return set
        case .dictionary(let dictionary): return dictionary
        case .tuple(let tuple): return tuple
        case .range(let range): return range
        case .optional(let optional): return optional.wrapped?.hostPayload
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .host(let any): return any as? Int
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .host(let any):
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            return nil
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let string): return string
        case .host(let any): return any as? String
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .host(let any): return any as? Bool
        default: return nil
        }
    }

    public var arrayValue: [RuntimeValue]? {
        switch self {
        case .array(let array): return array
        case .host(let any):
            if let array = any as? [RuntimeValue] { return array }
            if let buffer = any as? RuntimeCollectionBackedBuffer {
                return buffer.elements
            }
            // Foundation.Data is a concrete RandomAccessCollection<UInt8>;
            // expose its elements to generic Sequence/Array construction
            // without requiring a Data-specific constructor overload.
            if let data = any as? Data {
                return data.map { .native(Int($0)) }
            }
            return nil
        default: return nil
        }
    }

    public var setValue: RuntimeSetValue? {
        switch self {
        case .set(let set): return set
        case .host(let any): return any as? RuntimeSetValue
        default: return nil
        }
    }

    /// Elements of collection cases whose storage is directly iterable.
    /// Arrays and sets stay distinct for mutation, equality, and type
    /// matching; callers that only need Sequence semantics use this view.
    public var collectionElements: [RuntimeValue]? {
        switch self {
        case .array(let array): return array
        case .set(let set): return set.elements
        case .host(let any):
            if let array = any as? [RuntimeValue] { return array }
            if let buffer = any as? RuntimeCollectionBackedBuffer {
                return buffer.elements
            }
            if let set = any as? RuntimeSetValue { return set.elements }
            if let data = any as? Data {
                return data.map { .native(Int($0)) }
            }
            return nil
        default: return nil
        }
    }

    public var rangeValue: RuntimeRangeValue? {
        switch self {
        case .range(let range): return range
        case .host(let any): return RuntimeRangeValue.fromNative(any)
        default: return nil
        }
    }

    public var dictValue: DictValue? {
        switch self {
        case .dictionary(let dictionary): return dictionary
        case .host(let any): return any as? DictValue
        default: return nil
        }
    }

    public var tupleValue: TupleValue? {
        switch self {
        case .tuple(let tuple): return tuple
        case .host(let any): return any as? TupleValue
        default: return nil
        }
    }

    public var closureValue: ClosureValue? {
        if case .closure(let c) = self { return c }
        return nil
    }

    public var isNil: Bool {
        switch self {
        case .nilValue: return true
        case .optional(let optional): return optional.wrapped == nil
        default: return false
        }
    }

    /// String conversion matching Swift string-interpolation output closely
    /// enough for demo programs (`"Count: \(count)"`).
    public var stringified: String {
        switch self {
        case .void: return "()"
        case .nilValue: return "nil"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .string(let string): return string
        case .array(let array):
            return "[" + array.map(\.debugStringified).joined(separator: ", ") + "]"
        case .set(let set): return set.description
        case .optional(let optional):
            guard let wrapped = optional.wrapped else { return "nil" }
            return "Optional(\(wrapped.debugStringified))"
        case .dictionary(let dictionary): return dictionary.description
        case .tuple(let tuple): return tuple.description
        case .range(let range): return range.description
        case .host(let any):
            if let arr = any as? [RuntimeValue] {
                return "[" + arr.map(\.debugStringified).joined(separator: ", ") + "]"
            }
            if let set = any as? RuntimeSetValue { return set.description }
            if let dict = any as? DictValue { return dict.description }
            if let tuple = any as? TupleValue { return tuple.description }
            return String(describing: any)
        case .instance(let instance): return instance.description
        case .closure: return "(closure)"
        case .hostFunction(let f): return "(function \(f.name))"
        case .type(let symbol): return symbol.name
        case .enumType(let symbol): return symbol.name
        case .enumCase(let value): return value.description
        case .implicitMember(let name): return ".\(name)"
        }
    }

    /// The `String(reflecting:)` form used when a value appears as an ELEMENT
    /// of a container. Swift renders container members with reflecting
    /// semantics, so a String element shows quoted and escaped (`["a"]`, not
    /// `[a]`; `Optional("a")`, not `Optional(a)`; `Foo(name: "a")`, not
    /// `Foo(name: a)`). Only String differs from `stringified`; every other
    /// value nests through `stringified`, whose container cases route their
    /// own elements back through here, so quoting stays recursive.
    public var debugStringified: String {
        if let string = stringValue { return String(reflecting: string) }
        return stringified
    }
}

/// `self` inside an EnvironmentValues computed getter: `self[Key.self]`
/// answers the key type's static defaultValue (the pre-@Entry pattern).
public nonisolated final class EnvironmentValuesStub: Sendable {
    public init() {}
}

/// A generic TYPE APPLICATION carried textually (`PaginatedResponse<Movie>`)
/// — the decode bridge re-parses it to bind the struct's own generics.
public nonisolated struct GenericApplication: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// A call on an implicit member expression, e.g. `.system(size: 40)` — carried
/// opaquely until a gateway resolves it against the parameter's expected type.
@MainActor
public struct ImplicitMemberCall {
    public let name: String
    public let arguments: CallArguments
    /// The HOST type this marker was minted against, when known
    /// (`UNAuthorizationStatus.notDetermined` → "UNAuthorizationStatus") —
    /// user extensions of that type dispatch on the marker through it.
    public let typeHint: String?

    public init(name: String, arguments: CallArguments, typeHint: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.typeHint = typeHint
    }
}

/// Markers stand for cases of types the interpreter can't see — pattern
/// matching reads their name (`switch self { case .authorized: … }` inside
/// a user extension of a host enum).
extension ImplicitMemberCall: CaseShaped {
    public var caseName: String { name }
    public var casePayloads: [RuntimeValue] { arguments.arguments.map(\.value) }
}

/// A member (and optional call) chained onto an unresolved marker, e.g.
/// `.blue.opacity(0.2)` or `.easeInOut(duration: 0.3).delay(0.2)` — resolved
/// recursively at gateway boundaries. `base` is the full previous marker
/// (implicit member, ImplicitMemberCall, or another chain).
@MainActor
public struct ChainedImplicitCall {
    public let base: RuntimeValue
    public let member: String
    public let arguments: CallArguments

    public init(base: RuntimeValue, member: String, arguments: CallArguments) {
        self.base = base
        self.member = member
        self.arguments = arguments
    }

    /// The root implicit-member name when the base is a bare `.name`.
    public var baseName: String? {
        if case .implicitMember(let name) = base { return name }
        return nil
    }
}

/// `$published` inside an ObservableObject — the Combine publisher
/// projection. Pipelines chain inertly (debounce/removeDuplicates/sink all
/// absorb) and never emit headlessly: timers and debounce schedulers don't
/// run, so the honest behavior is a silent pipeline.
public nonisolated struct PublishedProjection: Sendable, InertCallable {
    public init() {}
}

/// Bridge stub types conform so calling them is inert-chainable
/// (`vc.present(alert, animated: true)` on a UIKit hosting stub).
public nonisolated protocol InertCallable {}

/// Host values that stand for enum cases (the bridge's Result carrier):
/// pattern matching and bare-case comparisons read this shape.
@MainActor
public protocol CaseShaped {
    var caseName: String { get }
    var casePayloads: [RuntimeValue] { get }
}

/// `/AppAction.milestone` — the CasePaths/TCA case-path prefix operator.
/// The path itself is inert: whatever consumes it (reducer scoping,
/// pullbacks) is external framework machinery that absorbs markers.
@MainActor
public struct CasePathMarker: InertCallable {
    public let path: String
    /// Resolved case reference (`/AppAction.milestone`): extraction and
    /// embedding become REAL when the enum is interpreted.
    public let enumSymbol: EnumSymbol?
    public let caseName: String?

    public init(path: String, enumSymbol: EnumSymbol? = nil, caseName: String? = nil) {
        self.path = path
        self.enumSymbol = enumSymbol
        self.caseName = caseName
    }
}

/// `super` inside a class body: member access dispatches to the interpreted
/// superclass when one exists, and is inert for host superclasses (NSObject,
/// UIViewController, …) whose initializers have no interpreter analog.
@MainActor
public struct SuperReference {
    public let instance: Instance
    /// The declaration containing the `super` expression. Dynamic self can
    /// be a deeper subclass while inherited initializer/method bodies run.
    public let dispatchOwner: StructSymbol

    public init(instance: Instance, dispatchOwner: StructSymbol) {
        self.instance = instance
        self.dispatchOwner = dispatchOwner
    }
}

/// `objectWillChange` on interpreted ObservableObjects — `.send()` fires
/// the instance's change signal (live views re-render); other pipeline
/// members chain inertly.
@MainActor
public final class ObjectWillChangePublisher: InertCallable {
    public let fire: @MainActor () -> Void

    public init(fire: @escaping @MainActor () -> Void) {
        self.fire = fire
    }
}

/// A `lazy var` instance property's pending initializer: evaluated with
/// `self` bound on FIRST ACCESS, then replaced by the value.
@MainActor
public final class LazyMemberSeed {
    public let initializer: ExprSyntax
    public let annotation: TypeSyntax?

    public init(initializer: ExprSyntax, annotation: TypeSyntax?) {
        self.initializer = initializer
        self.annotation = annotation
    }
}

/// The product of an interpreted `encoder.encode(value)`: written via
/// `data.write(to:)` it lands in the in-run blob store; `Data(contentsOf:)`
/// returns it and `decoder.decode(_:from:)` unwraps the ORIGINAL value —
/// real persistence semantics within a run.
@MainActor
public final class EncodedValueBlob {
    public let value: RuntimeValue

    public init(value: RuntimeValue) {
        self.value = value
    }
}

public nonisolated struct KeyPathStub: Sendable {
    /// `\.account.emojis` → ["account", "emojis"]; `\.self` → ["self"].
    public var components: [String] = []

    public init(components: [String] = []) {
        self.components = components
    }
}

/// `KeyPathComparator(\Order.status, order: .reverse)` / `SortDescriptor`:
/// a key path + direction, applied by `sorted(using:)`.
public nonisolated struct KeyPathComparatorBox: Sendable {
    public let keyPath: KeyPathStub
    public let ascending: Bool

    public init(keyPath: KeyPathStub, ascending: Bool) {
        self.keyPath = keyPath
        self.ascending = ascending
    }
}

/// An uppercase identifier that resolved to no known type or constructor —
/// assumed to be a host type used for static access (`Color.red`,
/// `UIScreen.main`). Member access on it yields an implicit member; calling
/// it is a located error.
public nonisolated struct HostTypeMarker: Sendable {
    public let name: String
    public let genericArguments: [String]

    public init(name: String, genericArguments: [String] = []) {
        self.name = name
        self.genericArguments = genericArguments
    }
}

/// The value of `$model` where model is @StateObject/@ObservedObject: member
/// access projects a `BindingStub` onto the model's property box, so
/// `TextField("…", text: $store.query)` works.
@MainActor
public struct ModelProjection {
    public let model: Instance

    public init(model: Instance) {
        self.model = model
    }
}
