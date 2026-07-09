/// The value of a `$property` projection on an `@State` property: a handle to
/// the state's Box. The bridge coerces it into a real `Binding<Bool/Double/
/// String>` whose setter writes the box — which fires `onChange` and therefore
/// re-renders, the same path Button actions use.
public final class BindingStub {
    public let box: Box

    public init(box: Box) {
        self.box = box
    }

    /// `ForEach($items) { $item in … }` — one binding per element, whose
    /// writes land back in the parent array (notifying, like any state
    /// write). Nil when the box doesn't hold an array.
    public func elementBindings() -> [RuntimeValue]? {
        guard let array = box.value.arrayValue else { return nil }
        let parent = box
        return array.indices.map { index in
            let element = Box(array[index])
            element.onChange = {
                guard var updated = parent.value.arrayValue,
                      updated.indices.contains(index) else { return }
                updated[index] = element.value
                parent.value = .native(updated)
            }
            return .native(BindingStub(box: element))
        }
    }
}
