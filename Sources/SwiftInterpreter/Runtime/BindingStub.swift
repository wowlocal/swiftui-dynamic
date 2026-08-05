/// The value of a `$property` projection on an `@State` property: a handle to
/// the state's Box. The bridge coerces it into a real `Binding<T>` — for
/// whichever `T` the value vocabulary carries — whose setter writes the box,
/// which fires `onChange` and therefore re-renders, the same path Button
/// actions use.
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
