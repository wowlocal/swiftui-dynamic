/// The value of a `$property` projection on an `@State` property: a handle to
/// the state's Box. The bridge coerces it into a real `Binding<Bool/Double/
/// String>` whose setter writes the box — which fires `onChange` and therefore
/// re-renders, the same path Button actions use.
@MainActor
public final class BindingStub {
    public let box: Box

    public init(box: Box) {
        self.box = box
    }

    /// `$items[index]` — a binding to one element, whose writes land back in
    /// the parent array (notifying, like any state write).
    public func elementBinding(at index: Int) -> RuntimeValue? {
        guard let array = box.value.arrayValue, array.indices.contains(index) else { return nil }
        let parent = box
        let element = Box(array[index])
        element.onChange = {
            guard var updated = parent.value.arrayValue,
                  updated.indices.contains(index) else { return }
            updated[index] = element.value.copiedForValueSemantics()
            parent.value = RuntimeValue.native(updated).copiedForValueSemantics()
        }
        return .native(BindingStub(box: element))
    }

    /// `ForEach($items) { $item in … }` — one binding per element. Nil when
    /// the box doesn't hold an array.
    public func elementBindings() -> [RuntimeValue]? {
        guard let array = box.value.arrayValue else { return nil }
        return array.indices.compactMap { elementBinding(at: $0) }
    }
}

extension Interpreter {
    /// The storage a `@Binding` property adopts for an incoming value, or nil
    /// when the value is not a binding at all.
    ///
    /// A binding reaches a `@Binding` property in TWO spellings, and both mean
    /// "this property is bound to that storage":
    ///
    /// - a projection (`$x`, `$viewModel.tag`) — a `BindingStub`, whose box is
    ///   SHARED so the child's writes land in the parent's state;
    /// - `Binding.constant(v)` — an `ImplicitMemberCall`, which has no upstream
    ///   to write back to, so it gets a fresh private box holding the payload.
    ///
    /// Every boundary that seeds a `@Binding` property has to answer both. One
    /// that answers only the projection leaves the `.constant` MARKER to be
    /// coerced into the property's declared type, and a marker is not a value
    /// of that type: the coercion yields a fresh empty stand-in, so
    /// `.constant("hello")` reads back as `""` and — worse, because it is
    /// silent — `.constant(nil)` reads back as a non-nil placeholder that
    /// `if let` happily unwraps.
    func bindingStorage(
        for value: RuntimeValue, property: StructSymbol.StoredProperty
    ) throws -> Box? {
        guard property.wrapper == .binding, case .host(let any) = value else {
            return nil
        }
        if let stub = any as? BindingStub { return stub.box }
        guard let call = any as? ImplicitMemberCall, call.name == "constant"
        else { return nil }
        return Box(try resolveAnnotated(
            call.arguments.positional(0) ?? .void,
            typeName: property.typeName).copiedForValueSemantics())
    }
}
