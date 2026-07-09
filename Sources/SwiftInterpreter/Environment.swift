/// A mutable binding. Environments hand out Boxes rather than values so that
/// closures capturing an environment see later mutations — matching Swift's
/// capture-by-reference semantics for `var`s. `@State` storage is also a Box;
/// its `onChange` observer is what drives SwiftUI re-rendering.
public final class Box {
    public var value: RuntimeValue {
        didSet { onChange?() }
    }
    public var onChange: (@MainActor () -> Void)?

    public init(_ value: RuntimeValue) {
        self.value = value
    }
}

/// A lexical scope: a dictionary of named Boxes with a parent chain
/// (block → closure/method → globals).
public final class Environment {
    public let parent: Environment?
    private var bindings: [String: Box] = [:]

    public init(parent: Environment? = nil) {
        self.parent = parent
    }

    public func define(_ name: String, _ value: RuntimeValue) {
        bindings[name] = Box(value)
    }

    /// Bind a name to an EXISTING box — reads stay live and writes propagate
    /// (used for `$item` closure parameters, where `item` shares the
    /// binding's storage).
    public func define(_ name: String, sharing box: Box) {
        bindings[name] = box
    }

    public func box(for name: String) -> Box? {
        bindings[name] ?? parent?.box(for: name)
    }

    public func lookup(_ name: String) -> RuntimeValue? {
        box(for: name)?.value
    }
}
