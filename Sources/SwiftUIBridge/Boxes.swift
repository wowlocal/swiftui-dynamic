import SwiftUI
import SwiftInterpreter

/// AttributedString styling — `var s = AttributedString("…"); if let range =
/// s.range(of: "x") { s[range].foregroundColor = .white }` — backed by the
/// real Foundation type; `Text(s)` renders the styled result.
final class AttributedStringBox: CustomStringConvertible,
    GeneratedMemberCarrier, GeneratedAttributedTextCarrier {
    var attributed: AttributedString

    /// The plain characters — trace-arg recording and interpolation read
    /// the text, never the type name.
    var description: String { String(attributed.characters) }

    init(_ attributed: AttributedString) {
        self.attributed = attributed
    }

    var generatedMemberValue: Any { attributed }
    var generatedAttributedText: AttributedString { attributed }

    func writeGeneratedMemberValue(_ value: Any) -> Bool {
        guard let value = value as? AttributedString else { return false }
        attributed = value
        return true
    }

    func replacingGeneratedMemberValue(_ value: Any) -> Any? {
        (value as? AttributedString).map(AttributedStringBox.init)
    }
}

/// A range from `range(of:)`, carried opaquely to the subscript.
final class AttributedRangeBox: GeneratedAttributedTextRangeCarrier {
    let range: Range<AttributedString.Index>

    var generatedAttributedTextRange: Range<AttributedString.Index> { range }

    init(_ range: Range<AttributedString.Index>) {
        self.range = range
    }
}

/// One styled slice (`s[range]`): attribute writes apply to the parent box.
final class AttributedRangeProxy: CustomStringConvertible,
    GeneratedAttributedTextCarrier {
    let box: AttributedStringBox
    let range: Range<AttributedString.Index>

    init(box: AttributedStringBox, range: Range<AttributedString.Index>) {
        self.box = box
        self.range = range
    }

    var generatedAttributedText: AttributedString {
        AttributedString(box.attributed[range])
    }

    var description: String { String(generatedAttributedText.characters) }
}

/// `Text` remains type-preserving until a consumer requires view erasure.
/// This lets generated SDK bridges pass interpreted `Text(...)` values to
/// concrete `Text` parameters such as ContentUnavailableView's description.
final class TextBox: GeneratedBinaryOperatorCarrier, GeneratedMemberCarrier {
    let text: Text
    var generatedMemberValue: Any { text }

    init(_ text: Text) {
        self.text = text
    }

    func applyingGeneratedBinaryOperator(
        _ op: String, rhs: Any
    ) -> Any? {
        guard op == "+", let rhs = rhs as? TextBox else { return nil }
        return TextBox(text + rhs.text)
    }
}

/// `Image` flows through the interpreter as an ImageBox rather than AnyView so
/// Image-typed modifiers (`.resizable()`) can still apply before the value is
/// erased. Converting to AnyView happens lazily in `ViewRegistry.anyView`.
///
/// SwiftUI-magic allowlist entry (first attachment provider): the interface
/// declares `Text.init(Image)` and image interpolation, but does not expose
/// `LocalizedStringKey`'s opaque typed-segment storage. Conformance carries
/// that missing relationship without an Image/API-name branch in evaluation.
protocol SwiftUITextInterpolationAttachment:
    RuntimeStringInterpolationAttachment
{
    var swiftUITextInterpolation: Text { get }
}

final class ImageBox:
    SwiftUITextInterpolationAttachment, GeneratedMemberCarrier
{
    let image: Image

    var swiftUITextInterpolation: Text { Text(image) }
    var generatedMemberValue: Any { image }

    init(_ image: Image) {
        self.image = image
    }
}

/// Shapes (`Circle()`, `RoundedRectangle(...)`) stay shape-typed so `.fill`/
/// `.stroke` can apply; used directly in view position they render as views.
final class ShapeBox {
    let shape: AnyShape
    /// SwiftUI-magic allowlist entry (concrete Shape operations): the
    /// interface exposes generic fill/stroke/clip operations, but AnyShape
    /// erasure can change their rasterization. Capture those operations while
    /// the concrete Shape type is still open.
    let fillPainter: (@MainActor (AnyShapeStyle) -> AnyView)
    let strokePainter: (@MainActor (AnyShapeStyle, CGFloat) -> AnyView)
    let strokePlainPainter: (@MainActor (CGFloat) -> AnyView)
    let clipApplier: (@MainActor (AnyView) -> AnyView)
    /// Real inside-stroke, retained at construction when the concrete
    /// shape is Insettable (erasure loses the conformance; FoodTruck's
    /// tile outlines need the true inset, not a centered approximation).
    let strokeBorderPainter: (@MainActor (AnyShapeStyle, CGFloat) -> AnyView)?
    /// Real `.containerShape(_:)`, same doctrine: the modifier's generic
    /// is InsettableShape-bound, so the applier captures the CONCRETE
    /// shape at construction (FoodTruck's continuous card corners flow
    /// to every ContainerRelativeShape fill/clip inside).
    let containerShapeApplier: (@MainActor (AnyView) -> AnyView)?
    /// The style-LESS inside-stroke — native `strokeBorder(lineWidth:)`
    /// reads the environment foreground style (the social-feed avatar
    /// rings are .tertiary via a view modifier, not an argument).
    let strokeBorderPlainPainter: (@MainActor (CGFloat) -> AnyView)?

    init(_ shape: some Shape) {
        self.shape = AnyShape(shape)
        self.fillPainter = { style in
            AnyView(shape.fill(style))
        }
        self.strokePainter = { style, lineWidth in
            AnyView(shape.stroke(style, lineWidth: lineWidth))
        }
        self.strokePlainPainter = { lineWidth in
            AnyView(shape.stroke(lineWidth: lineWidth))
        }
        self.clipApplier = { view in
            AnyView(view.clipShape(shape))
        }
        self.strokeBorderPainter = nil
        self.containerShapeApplier = nil
        self.strokeBorderPlainPainter = nil
    }

    init(insettable shape: some InsettableShape) {
        self.shape = AnyShape(shape)
        self.fillPainter = { style in
            AnyView(shape.fill(style))
        }
        self.strokePainter = { style, lineWidth in
            AnyView(shape.stroke(style, lineWidth: lineWidth))
        }
        self.strokePlainPainter = { lineWidth in
            AnyView(shape.stroke(lineWidth: lineWidth))
        }
        self.clipApplier = { view in
            AnyView(view.clipShape(shape))
        }
        self.strokeBorderPainter = { style, lineWidth in
            AnyView(shape.strokeBorder(style, lineWidth: lineWidth))
        }
        self.containerShapeApplier = { view in
            AnyView(view.containerShape(shape))
        }
        self.strokeBorderPlainPainter = { lineWidth in
            AnyView(shape.strokeBorder(lineWidth: lineWidth))
        }
    }

    /// Opens any interface-generated Shape existential into the same generic
    /// operation carrier used by handwritten/custom shapes. The conformance,
    /// rather than an SDK type name, selects the adapter; checking the
    /// stronger InsettableShape property first preserves its extra semantics.
    static func opening(_ value: Any) -> ShapeBox? {
        if let box = value as? ShapeBox {
            return box
        }
        if let shape = value as? any InsettableShape {
            return ShapeBox(insettable: shape)
        }
        if let shape = value as? any Shape {
            return ShapeBox(shape)
        }
        return nil
    }
}

/// ForEach's per-element views, carried un-erased so N-aware containers
/// (custom Layouts) splice REAL subviews; anyView() collapses it to the
/// indexed ForEach for every ordinary consumer.
final class ForEachFan {
    let views: [AnyView]
    /// The UNCOMPOSED builder output when this fan carries a @ViewBuilder
    /// member's result — section-aware containers (Form) unpack the raw
    /// values so SectionSpecs survive to their builders.
    let rawValues: [RuntimeValue]?

    init(views: [AnyView], rawValues: [RuntimeValue]? = nil) {
        self.views = views
        self.rawValues = rawValues
    }
}
