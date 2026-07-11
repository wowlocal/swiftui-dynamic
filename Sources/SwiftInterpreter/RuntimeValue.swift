import SwiftSyntax
/// The type-erased runtime representation of every value the interpreter touches.
///
/// The scalars every loop and comparison churns through (`Int`, `Double`,
/// `Bool`) live INLINE — reading them is a jump, not an existential dynamic
/// cast. Other native values (strings, arrays, and opaque host values such
/// as `AnyView`) live in `.host`; user-defined structs are `.instance`;
/// functions and closures are `.closure`; pre-compiled host gateways are
/// `.hostFunction`. Construct through the `native(_:)` factories, which
/// normalize scalars into their inline cases — `.host` never holds an
/// Int/Double/Bool (accessors stay tolerant regardless).
public enum RuntimeValue {
    case void
    case nilValue
    case int(Int)
    case double(Double)
    case bool(Bool)
    case host(Any)
    case instance(Instance)
    case closure(ClosureValue)
    case hostFunction(HostFunction)
    case type(StructSymbol)
    case enumType(EnumSymbol)
    case enumCase(EnumCaseValue)
    case implicitMember(String)

    @inline(__always) public static func native(_ value: Int) -> RuntimeValue { .int(value) }
    @inline(__always) public static func native(_ value: Double) -> RuntimeValue { .double(value) }
    @inline(__always) public static func native(_ value: Bool) -> RuntimeValue { .bool(value) }
    /// The untyped fallback: statically-scalar call sites bind the overloads
    /// above at compile time; `Any` payloads normalize here (this also
    /// unwraps optional scalars, matching the old `as? Int` read behavior;
    /// CGFloat bridges into `.double` the way `doubleValue` always read it).
    public static func native(_ value: Any) -> RuntimeValue {
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let b = value as? Bool { return .bool(b) }
        if let range = RuntimeRangeValue.fromNative(value) { return .host(range) }
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
        if case .host(let any) = self { return any as? String }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .host(let any): return any as? Bool
        default: return nil
        }
    }

    public var arrayValue: [RuntimeValue]? {
        if case .host(let any) = self { return any as? [RuntimeValue] }
        return nil
    }

    public var rangeValue: RuntimeRangeValue? {
        guard case .host(let any) = self else { return nil }
        return RuntimeRangeValue.fromNative(any)
    }

    public var dictValue: DictValue? {
        if case .host(let any) = self { return any as? DictValue }
        return nil
    }

    public var tupleValue: TupleValue? {
        if case .host(let any) = self { return any as? TupleValue }
        return nil
    }

    public var closureValue: ClosureValue? {
        if case .closure(let c) = self { return c }
        return nil
    }

    public var isNil: Bool {
        if case .nilValue = self { return true }
        return false
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
        case .host(let any):
            if let arr = any as? [RuntimeValue] {
                return "[" + arr.map(\.stringified).joined(separator: ", ") + "]"
            }
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
}

/// `self` inside an EnvironmentValues computed getter: `self[Key.self]`
/// answers the key type's static defaultValue (the pre-@Entry pattern).
public final class EnvironmentValuesStub {
    public init() {}
}

/// A generic TYPE APPLICATION carried textually (`PaginatedResponse<Movie>`)
/// — the decode bridge re-parses it to bind the struct's own generics.
public struct GenericApplication {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// A call on an implicit member expression, e.g. `.system(size: 40)` — carried
/// opaquely until a gateway resolves it against the parameter's expected type.
public struct ImplicitMemberCall {
    public let name: String
    public let arguments: CallArguments

    public init(name: String, arguments: CallArguments) {
        self.name = name
        self.arguments = arguments
    }
}

/// A member (and optional call) chained onto an unresolved marker, e.g.
/// `.blue.opacity(0.2)` or `.easeInOut(duration: 0.3).delay(0.2)` — resolved
/// recursively at gateway boundaries. `base` is the full previous marker
/// (implicit member, ImplicitMemberCall, or another chain).
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
public struct PublishedProjection: InertCallable {
    public init() {}
}

/// Bridge stub types conform so calling them is inert-chainable
/// (`vc.present(alert, animated: true)` on a UIKit hosting stub).
public protocol InertCallable {}

/// Host values that stand for enum cases (the bridge's Result carrier):
/// pattern matching and bare-case comparisons read this shape.
public protocol CaseShaped {
    var caseName: String { get }
    var casePayloads: [RuntimeValue] { get }
}

/// `/AppAction.milestone` — the CasePaths/TCA case-path prefix operator.
/// The path itself is inert: whatever consumes it (reducer scoping,
/// pullbacks) is external framework machinery that absorbs markers.
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
public struct SuperReference {
    public let instance: Instance

    public init(instance: Instance) {
        self.instance = instance
    }
}

/// `objectWillChange` on interpreted ObservableObjects — `.send()` fires
/// the instance's change signal (live views re-render); other pipeline
/// members chain inertly.
public final class ObjectWillChangePublisher: InertCallable {
    public let fire: () -> Void

    public init(fire: @escaping () -> Void) {
        self.fire = fire
    }
}

/// A `lazy var` instance property's pending initializer: evaluated with
/// `self` bound on FIRST ACCESS, then replaced by the value.
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
public final class EncodedValueBlob {
    public let value: RuntimeValue

    public init(value: RuntimeValue) {
        self.value = value
    }
}

public struct KeyPathStub {
    /// `\.account.emojis` → ["account", "emojis"]; `\.self` → ["self"].
    public var components: [String] = []

    public init(components: [String] = []) {
        self.components = components
    }
}

/// An uppercase identifier that resolved to no known type or constructor —
/// assumed to be a host type used for static access (`Color.red`,
/// `UIScreen.main`). Member access on it yields an implicit member; calling
/// it is a located error.
public struct HostTypeMarker {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// The value of `$model` where model is @StateObject/@ObservedObject: member
/// access projects a `BindingStub` onto the model's property box, so
/// `TextField("…", text: $store.query)` works.
public struct ModelProjection {
    public let model: Instance

    public init(model: Instance) {
        self.model = model
    }
}
