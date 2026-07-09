/// Evaluated call arguments in source order: labeled args first, then the
/// trailing closure (label nil) and any additional trailing closures (labeled).
public struct CallArguments {
    public struct Argument {
        public let label: String?
        public let value: RuntimeValue
        public let isTrailing: Bool

        public init(label: String?, value: RuntimeValue, isTrailing: Bool = false) {
            self.label = label
            self.value = value
            self.isTrailing = isTrailing
        }
    }

    public var arguments: [Argument]

    public init(arguments: [Argument] = []) {
        self.arguments = arguments
    }

    public var isEmpty: Bool { arguments.isEmpty }

    public func labeled(_ label: String) -> RuntimeValue? {
        arguments.first { $0.label == label }?.value
    }

    /// The n-th unlabeled, non-trailing argument (what a positional parameter binds).
    public func positional(_ index: Int) -> RuntimeValue? {
        let positionals = arguments.filter { $0.label == nil && !$0.isTrailing }
        guard index < positionals.count else { return nil }
        return positionals[index].value
    }

    public func closure(labeled label: String) -> ClosureValue? {
        labeled(label)?.closureValue
    }

    /// Unlabeled closures in order (explicit unlabeled args and the first trailing closure).
    public var unlabeledClosures: [ClosureValue] {
        arguments.filter { $0.label == nil }.compactMap(\.value.closureValue)
    }
}

/// A pre-compiled gateway into host (framework) functionality — the Bitrig
/// trick: instead of reimplementing SwiftUI, gateways accept dynamic arguments
/// and call the real API.
public struct HostFunction {
    public let name: String
    public let invoke: @MainActor (CallArguments, EvalContext) throws -> RuntimeValue

    public init(name: String, invoke: @escaping @MainActor (CallArguments, EvalContext) throws -> RuntimeValue) {
        self.name = name
        self.invoke = invoke
    }
}

/// A gateway for `.modifier(...)` calls on host view values.
public struct HostModifier {
    public let name: String
    public let apply: @MainActor (RuntimeValue, CallArguments, EvalContext) throws -> RuntimeValue

    public init(name: String, apply: @escaping @MainActor (RuntimeValue, CallArguments, EvalContext) throws -> RuntimeValue) {
        self.name = name
        self.apply = apply
    }
}

/// What gateways can ask of the interpreter mid-call: run an interpreted
/// closure (Button actions, ForEach content) or evaluate one in ViewBuilder
/// mode (container content).
public protocol EvalContext: AnyObject {
    func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue
    func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue]
}

/// Implemented by the SwiftUI bridge (and by the trace registry in tests).
/// The interpreter core never imports SwiftUI; view values flow through it
/// opaquely and all rendering decisions happen behind this protocol.
public protocol HostRegistry: AnyObject {
    func constructor(named name: String) -> HostFunction?
    func modifier(named name: String) -> HostModifier?
    func isViewValue(_ value: RuntimeValue) -> Bool
    /// Wrap a user-struct instance conforming to View into a renderable host value.
    func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue
    /// Group multiple builder-collected views into one (implicit TupleView stand-in).
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue
    /// Members on host-native values the core can't know (GeometryProxy.size,
    /// CGSize.width, …). Return nil for unknown names.
    func hostMember(_ name: String, on value: Any) -> RuntimeValue?
    /// Writable members on host-native values (formatter.dateFormat = "…").
    /// Return false when the member isn't settable.
    func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool
    /// Constructors for host object types (DateFormatter()) shared across
    /// real and trace registries. Return nil for unknown names.
    func hostObjectConstructor(named name: String) -> HostFunction?
    /// Host-typed operators the core can't know (`Text + Text`). Return nil
    /// to fall through to the numeric/string builtins.
    func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue?
    /// The host TYPE a native value stands for (AppStub → "UIApplication",
    /// a recorded node → its constructor name) so user extensions of host
    /// types dispatch on stubs. Nil when unknown.
    func hostTypeName(of value: Any) -> String?
    /// Value-type member writes (`size.width = 300`): return the MUTATED
    /// COPY, or nil when the member isn't writable this way.
    func hostMutatedCopy(settingMember name: String, on value: Any, to newValue: RuntimeValue) -> Any?
}

extension HostRegistry {
    public func combineValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) -> RuntimeValue? { nil }
    public func hostTypeName(of value: Any) -> String? { nil }
    public func hostMutatedCopy(settingMember name: String, on value: Any, to newValue: RuntimeValue) -> Any? { nil }
    public func hostMember(_ name: String, on value: Any) -> RuntimeValue? { nil }
    public func hostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool { false }
    public func hostObjectConstructor(named name: String) -> HostFunction? { nil }
}
