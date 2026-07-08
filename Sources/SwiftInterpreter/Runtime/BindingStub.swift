/// The value of a `$property` projection on an `@State` property: a handle to
/// the state's Box. The bridge coerces it into a real `Binding<Bool/Double/
/// String>` whose setter writes the box — which fires `onChange` and therefore
/// re-renders, the same path Button actions use.
public final class BindingStub {
    public let box: Box

    public init(box: Box) {
        self.box = box
    }
}
