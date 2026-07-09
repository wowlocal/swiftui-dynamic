/// The type-erased runtime representation of every value the interpreter touches.
///
/// Native values (numbers, strings, arrays, and opaque host values such as
/// `AnyView`) live in `.native`; user-defined structs are `.instance`; functions
/// and closures are `.closure`; pre-compiled host gateways are `.hostFunction`.
public enum RuntimeValue {
    case void
    case nilValue
    case native(Any)
    case instance(Instance)
    case closure(ClosureValue)
    case hostFunction(HostFunction)
    case type(StructSymbol)
    case enumType(EnumSymbol)
    case enumCase(EnumCaseValue)
    case implicitMember(String)
}

extension RuntimeValue {
    public var intValue: Int? {
        if case .native(let any) = self { return any as? Int }
        return nil
    }

    public var doubleValue: Double? {
        if case .native(let any) = self {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
        }
        return nil
    }

    public var stringValue: String? {
        if case .native(let any) = self { return any as? String }
        return nil
    }

    public var boolValue: Bool? {
        if case .native(let any) = self { return any as? Bool }
        return nil
    }

    public var arrayValue: [RuntimeValue]? {
        if case .native(let any) = self { return any as? [RuntimeValue] }
        return nil
    }

    public var rangeValue: Range<Int>? {
        if case .native(let any) = self { return any as? Range<Int> }
        return nil
    }

    public var dictValue: DictValue? {
        if case .native(let any) = self { return any as? DictValue }
        return nil
    }

    public var tupleValue: TupleValue? {
        if case .native(let any) = self { return any as? TupleValue }
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
        case .native(let any):
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

/// `super` inside a class body: member access dispatches to the interpreted
/// superclass when one exists, and is inert for host superclasses (NSObject,
/// UIViewController, …) whose initializers have no interpreter analog.
public struct SuperReference {
    public let instance: Instance

    public init(instance: Instance) {
        self.instance = instance
    }
}

/// Marker for key-path literals like `\.self`; gateways that take `id:` ignore it.
public struct KeyPathStub {
    public init() {}
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
