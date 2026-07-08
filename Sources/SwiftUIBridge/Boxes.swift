import SwiftUI

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
