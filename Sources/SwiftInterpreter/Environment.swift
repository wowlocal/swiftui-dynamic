import SwiftSyntax

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

/// A top-level global not yet initialized — real Swift globals are lazy, so
/// forward/cross-file references work. Forced (evaluated + replaced) on
/// first read.
public final class LazyGlobal {
    public let initializer: ExprSyntax?
    public let annotation: TypeSyntax?

    public init(initializer: ExprSyntax?, annotation: TypeSyntax?) {
        self.initializer = initializer
        self.annotation = annotation
    }
}

/// `var uptime: String { … }` at FILE scope — a global computed property:
/// the accessor evaluates on every read (never cached).
public final class ComputedGlobal {
    public let accessor: CodeBlockItemListSyntax
    public let annotation: TypeSyntax?

    public init(accessor: CodeBlockItemListSyntax, annotation: TypeSyntax?) {
        self.accessor = accessor
        self.annotation = annotation
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

    /// Walks the chain but stops BEFORE `boundary` (exclusive): lets lookup
    /// consult locals without the global tail, so implicit-self members can
    /// shadow globals the way real Swift scoping does.
    public func box(for name: String, before boundary: Environment) -> Box? {
        if self === boundary { return nil }
        return bindings[name] ?? parent?.box(for: name, before: boundary)
    }

    public func lookup(_ name: String) -> RuntimeValue? {
        box(for: name)?.value
    }
}
