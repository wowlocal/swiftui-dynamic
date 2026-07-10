import SwiftUI

/// AttributedString styling — `var s = AttributedString("…"); if let range =
/// s.range(of: "x") { s[range].foregroundColor = .white }` — backed by the
/// real Foundation type; `Text(s)` renders the styled result.
final class AttributedStringBox: CustomStringConvertible {
    var attributed: AttributedString

    /// The plain characters — trace-arg recording and interpolation read
    /// the text, never the type name.
    var description: String { String(attributed.characters) }

    init(_ attributed: AttributedString) {
        self.attributed = attributed
    }
}

/// A range from `range(of:)`, carried opaquely to the subscript.
final class AttributedRangeBox {
    let range: Range<AttributedString.Index>

    init(_ range: Range<AttributedString.Index>) {
        self.range = range
    }
}

/// One styled slice (`s[range]`): attribute writes apply to the parent box.
final class AttributedRangeProxy {
    let box: AttributedStringBox
    let range: Range<AttributedString.Index>

    init(box: AttributedStringBox, range: Range<AttributedString.Index>) {
        self.box = box
        self.range = range
    }
}

/// `Image` flows through the interpreter as an ImageBox rather than AnyView so
/// Image-typed modifiers (`.resizable()`) can still apply before the value is
/// erased. Converting to AnyView happens lazily in `ViewRegistry.anyView`.
final class ImageBox {
    let image: Image

    init(_ image: Image) {
        self.image = image
    }
}

/// Shapes (`Circle()`, `RoundedRectangle(...)`) stay shape-typed so `.fill`/
/// `.stroke` can apply; used directly in view position they render as views.
final class ShapeBox {
    let shape: AnyShape

    init(_ shape: some Shape) {
        self.shape = AnyShape(shape)
    }
}
