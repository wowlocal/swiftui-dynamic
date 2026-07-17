import SwiftSyntax

/// The ownership carried by a Swift storage edge. Reference ownership belongs
/// to the variable/property/capture slot, not to `RuntimeValue`: the same class
/// value may be held strongly in one box and weakly in another.
public nonisolated enum ReferenceOwnership: Sendable, Equatable {
    case strong
    case weak
    case unowned
    case unownedUnsafe

    public init(modifiers: DeclModifierListSyntax) {
        guard let modifier = modifiers.first(where: {
            $0.name.text == "weak" || $0.name.text == "unowned"
        }) else {
            self = .strong
            return
        }
        if modifier.name.text == "weak" {
            self = .weak
        } else if modifier.trimmedDescription.contains("unsafe") {
            self = .unownedUnsafe
        } else {
            self = .unowned
        }
    }

    public init(captureSpecifier: ClosureCaptureSpecifierSyntax?) {
        guard let captureSpecifier else {
            self = .strong
            return
        }
        if captureSpecifier.specifier.text == "weak" {
            self = .weak
        } else if captureSpecifier.detail?.text == "unsafe" {
            self = .unownedUnsafe
        } else {
            self = .unowned
        }
    }
}

/// Weak host/interpreted target storage. Safe unowned references deliberately
/// use the same zeroing host primitive: the interpreter converts a missing
/// formerly-live target into its own RuntimeError instead of crashing the host
/// process with a native dangling-unowned trap.
@MainActor
private final class RuntimeReferenceStorage {
    enum TargetKind {
        case interpreted
        case host
        case none
    }

    weak var interpreted: Instance?
    weak var host: AnyObject?
    var targetKind: TargetKind = .none
    var wasAssignedObject = false
    var wasExplicitlyNil = false
    var isOptional = false
    var wrappedTypeName: String?
    var isImplicitlyUnwrapped = false

    func assign(_ value: RuntimeValue, declaredTypeName: String?) {
        interpreted = nil
        host = nil
        targetKind = .none
        wasAssignedObject = false
        wasExplicitlyNil = false

        if let declaredTypeName,
           let wrapped = RuntimeOptionalValue.wrappedType(in: declaredTypeName) {
            isOptional = true
            wrappedTypeName = wrapped
            isImplicitlyUnwrapped = declaredTypeName
                .trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("!")
        } else {
            isOptional = false
            wrappedTypeName = nil
            isImplicitlyUnwrapped = false
        }

        let target: RuntimeValue?
        switch value {
        case .optional(let optional):
            isOptional = true
            wrappedTypeName = optional.wrappedTypeName ?? wrappedTypeName
            isImplicitlyUnwrapped = optional.isImplicitlyUnwrapped
            target = optional.wrapped
            wasExplicitlyNil = optional.wrapped == nil
        case .nilValue:
            isOptional = true
            target = nil
            wasExplicitlyNil = true
        default:
            target = value
        }

        guard let target else { return }
        switch target {
        case .instance(let instance):
            interpreted = instance
            targetKind = .interpreted
            wasAssignedObject = true
        case .host(let any):
            host = any as AnyObject
            targetKind = .host
            wasAssignedObject = true
        default:
            // Compiled Swift rejects weak/unowned value-type storage. Merged
            // sources have already passed a compiler, so an invalid dynamic
            // assignment is represented as an explicit nil rather than
            // retaining a value through what claims to be a non-owning edge.
            wasExplicitlyNil = true
        }
    }

    var liveValue: RuntimeValue? {
        switch targetKind {
        case .interpreted:
            return interpreted.map(RuntimeValue.instance)
        case .host:
            return host.map { .host($0) }
        case .none:
            return nil
        }
    }

    func materialized(for ownership: ReferenceOwnership) -> RuntimeValue {
        if let live = liveValue {
            if isOptional || ownership == .weak {
                return .some(
                    live, wrappedTypeName: wrappedTypeName,
                    isImplicitlyUnwrapped: isImplicitlyUnwrapped)
            }
            return live
        }

        if ownership == .weak || wasExplicitlyNil || !wasAssignedObject {
            return .none(
                wrappedTypeName: wrappedTypeName,
                isImplicitlyUnwrapped: isImplicitlyUnwrapped)
        }
        return .native(DanglingUnownedReference())
    }
}

private nonisolated struct DanglingUnownedReference: Sendable {}

/// A mutable binding. Environments hand out Boxes rather than values so that
/// closures capturing an environment see later mutations — matching Swift's
/// capture-by-reference semantics for `var`s. `@State` storage is also a Box;
/// its `onChange` observer is what drives SwiftUI re-rendering.
@MainActor
public final class Box {
    private enum Storage {
        case strong(RuntimeValue)
        case reference(RuntimeReferenceStorage)
    }

    private var storage: Storage
    public let referenceOwnership: ReferenceOwnership

    public var value: RuntimeValue {
        get { materializedValue }
        set {
            assign(newValue)
            mutationVersion &+= 1
            onChange?()
        }
    }
    public var onChange: (@MainActor () -> Void)?
    /// Monotonic value-storage generation for semantic caches. Consumers can
    /// retain a typed projection and cheaply prove it is still current; every
    /// language-level assignment advances the generation before observers run.
    private(set) var mutationVersion: UInt64 = 0
    /// Source annotation for this storage location. Kept after the established
    /// fields for incremental ABI stability; mutation dispatch uses it for
    /// generic element context even when a collection is empty.
    public var declaredTypeName: String?

    public init(
        _ value: RuntimeValue, declaredTypeName: String? = nil,
        referenceOwnership: ReferenceOwnership = .strong
    ) {
        self.referenceOwnership = referenceOwnership
        self.declaredTypeName = declaredTypeName
        switch referenceOwnership {
        case .strong:
            self.storage = .strong(value)
        case .weak, .unowned, .unownedUnsafe:
            // A lazy-global seed is evaluator metadata, not the source
            // variable's eventual value. Keep the seed alive strongly until
            // first access; assigning the evaluated result below converts the
            // slot to its declared non-owning policy.
            if case .host(let any) = value, any is LazyGlobal {
                self.storage = .strong(value)
            } else {
                let reference = RuntimeReferenceStorage()
                reference.assign(value, declaredTypeName: declaredTypeName)
                self.storage = .reference(reference)
            }
        }
    }

    private var materializedValue: RuntimeValue {
        switch storage {
        case .strong(let value):
            return value
        case .reference(let reference):
            return reference.materialized(for: referenceOwnership)
        }
    }

    private func assign(_ value: RuntimeValue) {
        switch referenceOwnership {
        case .strong:
            storage = .strong(value)
        case .weak, .unowned, .unownedUnsafe:
            let reference: RuntimeReferenceStorage
            if case .reference(let existing) = storage {
                reference = existing
            } else {
                reference = RuntimeReferenceStorage()
                storage = .reference(reference)
            }
            reference.assign(value, declaredTypeName: declaredTypeName)
        }
    }

    /// Language-level read, including the safe interpreter trap for a dead
    /// unowned reference. Internal compatibility paths may still inspect
    /// `value`; evaluator read funnels should use this method.
    public func load() throws -> RuntimeValue {
        let value = materializedValue
        if case .host(let marker) = value, marker is DanglingUnownedReference {
            throw RuntimeError(message: "attempted to read a deallocated unowned reference")
        }
        return value
    }
}

/// A top-level global not yet initialized — real Swift globals are lazy, so
/// forward/cross-file references work. Forced (evaluated + replaced) on
/// first read.
@MainActor
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
@MainActor
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
@MainActor
public final class Environment {
    private let retainedParent: Environment?
    private weak var unretainedParent: Environment?
    public var parent: Environment? { retainedParent ?? unretainedParent }
    private var bindings: [String: Box] = [:]

    public init(parent: Environment? = nil, retainingParent: Bool = true) {
        if retainingParent {
            self.retainedParent = parent
            self.unretainedParent = nil
        } else {
            self.retainedParent = nil
            self.unretainedParent = parent
        }
    }

    /// Define a new Swift binding. A fresh binding is a value-ownership
    /// boundary, so interpreted structs and containers receive independent
    /// storage while classes, closures, and host objects retain identity.
    public func define(
        _ name: String, _ value: RuntimeValue,
        declaredTypeName: String? = nil,
        referenceOwnership: ReferenceOwnership = .strong
    ) {
        bindings[name] = Box(
            value.copiedForValueSemantics(), declaredTypeName: declaredTypeName,
            referenceOwnership: referenceOwnership)
    }

    /// Bind an evaluator-owned borrow without introducing a language-level
    /// copy. `self` environments use this; mutation is committed explicitly
    /// by their lvalue/copy-out boundary.
    func defineBorrowing(_ name: String, _ value: RuntimeValue) {
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
