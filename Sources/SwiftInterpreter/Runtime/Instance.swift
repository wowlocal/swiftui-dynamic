/// Multicast change notification for observable model instances. Handlers are
/// keyed by observer identity so re-subscription (every body evaluation) stays
/// idempotent; observers hold themselves weakly inside their handlers.
@MainActor
public final class ChangeSignal {
    private var observers: [ObjectIdentifier: @MainActor () -> Void] = [:]

    public init() {}

    public func subscribe(_ key: ObjectIdentifier, _ handler: @escaping @MainActor () -> Void) {
        observers[key] = handler
    }

    public func fire() {
        for handler in observers.values { handler() }
    }

    public var observerCount: Int { observers.count }
}

/// Storage for an interpreted nominal value. Source structs use this mutable
/// node behind the runtime's explicit copy/write-back boundary; source classes
/// retain the node directly. The representation is shared, the semantics are
/// not: `RuntimeValue.copiedForValueSemantics()` is the ownership authority.
@MainActor
public final class Instance: @preconcurrency CustomStringConvertible {
    public let symbol: StructSymbol
    /// Present only for source actors. The ID selects the logical actor
    /// executor independently of the host object's memory address and is the
    /// future key for storage confinement and mailbox state.
    public internal(set) var actorID: RuntimeActorID?
    /// Fired when a notifying (@Published / @Observable-tracked) property mutates.
    public let changeSignal = ChangeSignal()
    /// Plain stored properties. `@Binding` properties live here too, but their
    /// Box is shared with the parent's state box rather than owned.
    public var properties: [String: Box] = [:]
    /// `@State`-marked properties, kept separate so the SwiftUI bridge can swap
    /// in persisted boxes across instance recreations.
    public var stateBoxes: [String: Box] = [:]
    /// Stored after the established public fields so incremental clients keep
    /// their existing offsets. Struct COW envelopes created while assigning
    /// `self` carry this observer-suppression state to the final value.
    var isInitializing = false
    /// The evaluator that owns this source-class lifetime. Weakness avoids an
    /// object -> interpreter -> globals -> object cycle; source structs leave
    /// it nil because their backing-node destruction is not a Swift `deinit`.
    weak var lifecycleOwner: Interpreter?
    var didRunDeinitializer = false
    /// `instantiateRoot` acts as the otherwise-absent embedding caller. Its
    /// synthesized arguments may be referenced by `weak`/`unowned` source
    /// properties, so the root value carries the caller's strong ownership
    /// lease. Ordinary source construction leaves this empty.
    var synthesizedRootOwners: [RuntimeValue] = []

    public init(symbol: StructSymbol, lifecycleOwner: Interpreter? = nil) {
        self.symbol = symbol
        self.lifecycleOwner = lifecycleOwner
    }

    isolated deinit {
        if symbol.isClass, !didRunDeinitializer {
            lifecycleOwner?.runDeinitializer(on: self)
        }
        if let actorID {
            lifecycleOwner?.concurrencyRuntime.releaseActor(actorID)
        }
    }

    public func box(for name: String) -> Box? {
        stateBoxes[name] ?? properties[name]
    }

    /// The box behind `$name` — an @State box or a shared @Binding box.
    public func projectedBox(for name: String) -> Box? {
        if let state = stateBoxes[name] { return state }
        if symbol.storedProperty(named: name)?.wrapper == .binding { return properties[name] }
        return nil
    }

    /// CYCLIC object graphs (protobuf parent/child links, shared DI
    /// instances) must not recurse describe-to-death: past a shallow
    /// nesting the description elides.
    private static var descriptionDepth = 0

    public var description: String {
        Self.descriptionDepth += 1
        defer { Self.descriptionDepth -= 1 }
        guard Self.descriptionDepth <= 3 else { return "\(symbol.name)(…)" }
        let props = symbol.storedProperties
            .compactMap { prop in box(for: prop.name).map { "\(prop.name): \($0.value.debugStringified)" } }
            .joined(separator: ", ")
        return "\(symbol.name)(\(props))"
    }
}

/// The REAL stdlib random algorithms drive an INTERPRETED generator: the
/// proxy's next() calls the interpreted `next()`, so ranged draws and
/// shuffles match a native run bit-for-bit (FoodTruck's seeded RNG genre).
extension Interpreter {
    /// The generator instance behind a `using:` argument — direct, inout-
    /// wrapped (BindingStub), or box-held (markers store inout args
    /// differently per call position).
    public func generatorInstance(from value: RuntimeValue?) -> Instance? {
        switch value {
        case .instance(let generator):
            return generator
        case .host(let any):
            if let stub = any as? BindingStub, case .instance(let generator) = stub.box.value {
                return generator
            }
            if let slot = any as? InoutSlot, case .instance(let generator) = slot.current {
                return generator
            }
            return nil
        default:
            return nil
        }
    }
}

@MainActor
public struct InterpretedGeneratorProxy:
    @preconcurrency RandomNumberGenerator
{
    let interpreter: Interpreter
    let generator: Instance

    public init(interpreter: Interpreter, generator: Instance) {
        self.interpreter = interpreter
        self.generator = generator
    }

    public mutating func next() -> UInt64 {
        guard let value = try? interpreter.callMethod(named: "next", on: generator, arguments: []) else {
            return 0
        }
        if case .host(let any) = value, let u = any as? UInt64 { return u }
        if let i = value.intValue { return UInt64(bitPattern: Int64(i)) }
        if let d = value.doubleValue { return UInt64(max(0, min(d, Double(UInt64.max)))) }
        return 0
    }
}
