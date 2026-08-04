#if canImport(UIKit) && targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import UIKit

/// The R2 board can say a screen diverges and `Scripts/pixel-diff-map.swift`
/// can say WHERE, but neither can say what the two sides actually built. The
/// media screen's residue is the case that needs it: every differing pixel is
/// an antialiased edge of one box, off by <= 2/255, which is what a box whose
/// frame differs in the third decimal looks like after rasterization. A
/// sub-pixel frame difference is invisible to a pixel diff — it can only be
/// read off the geometry the two hierarchies were laid out with.
///
/// So this emits the captured subtree as text, from BOTH capture paths, in one
/// canonical format that `Scripts/tree-diff.rb` can align: same file, compiled
/// into the interpreter's `IceCubesCheck` and into `IceCubesNativeTwin`, so
/// the two dumps cannot drift apart in formatting and read as a divergence.
///
/// Frames are reported converted into the CAPTURE view's coordinate space, at
/// full precision. Absolute position is the comparable quantity: the two sides
/// legitimately nest their hosting views differently, so a frame relative to a
/// parent that only one side has says nothing, while "this box's left edge is
/// at x=239.487 here and 239.470 there" is exactly the question a 0.017px
/// coverage difference asks.
///
/// Once the geometry agrees to 1e-6 and the residue is still edge-only, the
/// question stops being what was laid out and becomes how it was rasterized.
/// Four things answer that and none of them is a frame: WHERE the capture
/// landed (the `@capture` line, see `placement`), how each node turns its
/// geometry into coverage (see `coverage`), what bitmap the capture composited
/// into (the `@raster` line, see `raster`), and what colours each node
/// contributed to that blend (see `paint`).
///
/// One quantity is neither a frame nor a rasterization property and still
/// decides what gets built: a scroll view's CONTENT EXTENT (see `scroll`). It
/// has no view of its own, so a hierarchy dump cannot show it, yet it is what
/// UIKit consults before installing a scroller — and an extra scroller is the
/// tags-list screen's only structural difference between the two sides.
///
/// Reporting the destination bitmap replaces an argument that was made from
/// the artifacts and was not sound: both sides WRITE a 16-bit Display P3 PNG,
/// which was read as ruling out a blend-space difference, but the PNG is an
/// encoding of the result and says nothing about the space the blend happened
/// in. Measured through `@raster`, that space is float extended sRGB on both
/// sides — the same conclusion, now from the destination itself rather than
/// from its encoding.
enum CaptureGeometryDump {
    /// Set `ICECUBES_DUMP_TREE=1` to write `<screen>.tree` beside `<screen>.png`.
    /// Off by default: this is an instrument, never part of a scored capture.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ICECUBES_DUMP_TREE"] == "1"
    }

    /// Full precision, and no `-0`. `%.6f` keeps a Double's layout-relevant
    /// digits without printing the binary noise past them, so two sides that
    /// genuinely agree produce identical text rather than a diff of tails.
    private static func number(_ value: CGFloat) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        return String(format: "%.6f", rounded == 0 ? 0 : rounded)
    }

    private static func describe(
        _ view: UIView, in capture: UIView, depth: Int
    ) -> String {
        let frame = view.convert(view.bounds, to: capture)
        var parts = [
            String(repeating: "  ", count: depth)
                + String(describing: type(of: view)),
            "x=\(number(frame.minX))",
            "y=\(number(frame.minY))",
            "w=\(number(frame.width))",
            "h=\(number(frame.height))",
        ]
        // Only non-default compositing state is printed. A dump where every
        // node lists every property is one nobody reads; the properties that
        // change how an EDGE rasterizes are the ones worth a line.
        if view.isHidden { parts.append("hidden") }
        if view.alpha < 1 { parts.append("alpha=\(number(view.alpha))") }
        if view.clipsToBounds { parts.append("clips") }
        let layer = view.layer
        if layer.cornerRadius != 0 {
            parts.append("corner=\(number(layer.cornerRadius))")
        }
        if layer.borderWidth != 0 {
            parts.append("border=\(number(layer.borderWidth))")
        }
        if layer.opacity < 1 {
            parts.append("layerOpacity=\(number(CGFloat(layer.opacity)))")
        }
        if layer.mask != nil { parts.append("masked") }
        if layer.shouldRasterize { parts.append("rasterized") }
        if layer.contentsScale != 1 {
            parts.append("scale=\(number(layer.contentsScale))")
        }
        if !CATransform3DIsIdentity(layer.transform) {
            parts.append("transformed")
        }
        if layer.allowsEdgeAntialiasing { parts.append("edgeAA") }
        parts.append(contentsOf: coverage(of: layer))
        parts.append(contentsOf: paint(of: layer))
        parts.append(contentsOf: scroll(of: view))
        return parts.joined(separator: " ")
    }

    /// SwiftUI does not give every drawn thing a `UIView`. The media box's
    /// fill, its image and its 1-point stroke are all CALayers under one
    /// `_UIGraphicsView`, so a view-only dump bottoms out exactly above the
    /// content whose rasterization the R2 residue is about. Layers that back a
    /// subview are skipped — the view walk already describes those, and
    /// printing them twice would make one box look like two.
    private static func describe(
        _ layer: CALayer, in capture: UIView, depth: Int
    ) -> String {
        let frame = layer.convert(layer.bounds, to: capture.layer)
        var parts = [
            String(repeating: "  ", count: depth)
                + "@" + String(describing: type(of: layer)),
            "x=\(number(frame.minX))",
            "y=\(number(frame.minY))",
            "w=\(number(frame.width))",
            "h=\(number(frame.height))",
        ]
        if layer.isHidden { parts.append("hidden") }
        if layer.opacity < 1 {
            parts.append("opacity=\(number(CGFloat(layer.opacity)))")
        }
        if layer.cornerRadius != 0 {
            parts.append("corner=\(number(layer.cornerRadius))")
        }
        if layer.masksToBounds { parts.append("clips") }
        if layer.borderWidth != 0 {
            parts.append("border=\(number(layer.borderWidth))")
        }
        if layer.contents != nil { parts.append("contents") }
        if layer.mask != nil { parts.append("masked") }
        if layer.contentsScale != 1 {
            parts.append("scale=\(number(layer.contentsScale))")
        }
        if !CATransform3DIsIdentity(layer.transform) {
            parts.append("transformed")
        }
        if layer.allowsEdgeAntialiasing { parts.append("edgeAA") }
        parts.append(contentsOf: coverage(of: layer))
        parts.append(contentsOf: paint(of: layer))
        // A stroked shape is the one case where a sub-pixel difference is
        // legible as a number rather than as a rasterized edge, so a shape
        // layer reports the geometry it strokes.
        if let shape = layer as? CAShapeLayer {
            parts.append("lineWidth=\(number(shape.lineWidth))")
            if shape.strokeColor != nil { parts.append("stroked") }
            if shape.fillColor != nil { parts.append("filled") }
            if let path = shape.path {
                let box = path.boundingBoxOfPath
                parts.append(
                    "path=(\(number(box.minX)),\(number(box.minY)),"
                        + "\(number(box.width)),\(number(box.height)))")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func walk(
        _ layer: CALayer, in capture: UIView, skipping: Set<ObjectIdentifier>,
        depth: Int, into lines: inout [String]
    ) {
        for sublayer in layer.sublayers ?? [] {
            guard !skipping.contains(ObjectIdentifier(sublayer)) else { continue }
            lines.append(describe(sublayer, in: capture, depth: depth))
            walk(
                sublayer, in: capture, skipping: skipping,
                depth: depth + 1, into: &lines)
        }
    }

    private static func walk(
        _ view: UIView, in capture: UIView, depth: Int, into lines: inout [String]
    ) {
        lines.append(describe(view, in: capture, depth: depth))
        let viewBacked = Set(view.subviews.map { ObjectIdentifier($0.layer) })
        walk(
            view.layer, in: capture, skipping: viewBacked,
            depth: depth + 1, into: &lines)
        for child in view.subviews {
            walk(child, in: capture, depth: depth + 1, into: &lines)
        }
    }

    /// Where the capture view sits on the physical display, which is the one
    /// geometric fact the tree above cannot express: every frame in it is
    /// relative to the capture view, so two sides can agree on all of them and
    /// still rasterize differently. `drawHierarchy(afterScreenUpdates:)`
    /// composites through the window server, so content on HALF-point
    /// boundaries — the media box's stroke is at x=239.5, corner 10.5 — is
    /// antialiased according to where the window landed on the device pixel
    /// grid. Both harnesses pin the window's SIZE and neither pins its ORIGIN.
    ///
    /// Deliberately carries no `x=`/`y=`/`w=`/`h=` keys so `tree-diff.rb`
    /// skips it: this is the capture's placement, not a node in the tree.
    private static func placement(of captureView: UIView) -> String {
        let inWindow = captureView.convert(captureView.bounds, to: nil)
        var parts = [
            "@capture",
            "windowOrigin=(\(number(inWindow.minX)),\(number(inWindow.minY)))",
        ]
        if let window = captureView.window {
            let inScreen = window.convert(inWindow, to: nil)
            parts.append(
                "screenOrigin=(\(number(inScreen.minX)),"
                    + "\(number(inScreen.minY)))")
            let screen = window.screen
            parts.append("screenScale=\(number(screen.scale))")
            parts.append("nativeScale=\(number(screen.nativeScale))")
        } else {
            parts.append("screenOrigin=detached")
        }
        // The appearance the capture RESOLVED AGAINST, which is as much a
        // determinism input as the frozen clock and the frozen network: every
        // dynamic colour in the app — and `Color.gray` alone paints the media
        // box's fill and its 1-point stroke — is a different number in each
        // style, so a capture that inherits the host's setting silently scores
        // a different picture on a machine in the other mode.
        let traits = captureView.traitCollection
        parts.append("style=\(traits.userInterfaceStyle.rawValue)")
        parts.append("gamut=\(traits.displayGamut.rawValue)")
        parts.append("contrast=\(traits.accessibilityContrast.rawValue)")
        parts.append("level=\(traits.userInterfaceLevel.rawValue)")
        return parts.joined(separator: " ")
    }

    /// How a layer turns its geometry into COVERAGE, which is the half of
    /// rasterization the frames cannot express. Two layers can agree on
    /// x/y/w/h to 1e-6 and still put different alpha on the boundary pixel,
    /// because coverage is decided by the corner curve, by which edges are
    /// allowed to antialias at all, and — for a layer with contents — by how
    /// the backing image is mapped into those bounds and filtered on the way.
    ///
    /// This is aimed at the residue both remaining screens measure: 100% of
    /// media's 3410 differing pixels are the antialiased boundary of ONE
    /// rounded box, max 2/255, with the interpreted side covering ~0.01px more
    /// on all four sides symmetrically over a byte-identical tree. A symmetric
    /// sub-pixel widening is what a different corner curve, a different edge
    /// mask, or a differently-resampled image edge each look like; nothing
    /// already printed can tell them apart.
    ///
    /// Same rule as the rest of the dump: only non-default state gets a line.
    private static func coverage(of layer: CALayer) -> [String] {
        var parts: [String] = []
        // `cornerCurve` is the shape of the corner, not its size, so two
        // layers reporting the same `corner=10.5` can still round differently.
        if layer.cornerRadius != 0, layer.cornerCurve != .circular {
            parts.append("cornerCurve=\(layer.cornerCurve.rawValue)")
        }
        // `allowsEdgeAntialiasing` says whether, `edgeAntialiasingMask` says
        // which — a mask missing one edge is a hard edge on that side only.
        if layer.allowsEdgeAntialiasing,
            layer.edgeAntialiasingMask
                != [.layerLeftEdge, .layerRightEdge, .layerTopEdge,
                    .layerBottomEdge]
        {
            parts.append("edgeAAMask=\(layer.edgeAntialiasingMask.rawValue)")
        }
        guard layer.contents != nil else { return parts }
        // The media box's image is 450pt wide inside a 420pt clip, i.e. it is
        // MINIFIED. Which filter does that, and what pixel size it starts
        // from, decide the coverage of the pixels where the image ends.
        if layer.minificationFilter != .linear {
            parts.append("minFilter=\(layer.minificationFilter.rawValue)")
        }
        if layer.magnificationFilter != .linear {
            parts.append("magFilter=\(layer.magnificationFilter.rawValue)")
        }
        if layer.minificationFilterBias != 0 {
            parts.append(
                "minBias=\(number(CGFloat(layer.minificationFilterBias)))")
        }
        if layer.contentsGravity != .resize {
            parts.append("gravity=\(layer.contentsGravity.rawValue)")
        }
        // A sub-unit `contentsRect` is a symmetric inset of the source image
        // expressed in unit space — exactly the shape of a ~0.01px difference
        // on all four sides.
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        if layer.contentsRect != unit {
            parts.append("contentsRect=\(rect(layer.contentsRect))")
        }
        if layer.contentsCenter != unit {
            parts.append("contentsCenter=\(rect(layer.contentsCenter))")
        }
        // The source resolution itself: a placeholder decoded at a different
        // pixel size resamples to a different edge even into identical bounds.
        // `contents` is `Any?` holding a CoreFoundation object, and `as?` to a
        // CF type always succeeds, so the type has to be asked for by ID.
        let contents = layer.contents as CFTypeRef?
        if let contents, CFGetTypeID(contents) == CGImage.typeID {
            let image = unsafeBitCast(contents, to: CGImage.self)
            parts.append("contentsPixels=\(image.width)x\(image.height)")
            parts.append("contentsBits=\(image.bitsPerComponent)")
        }
        return parts
    }

    /// What a scroll view SCROLLS, which is not any of the frames above.
    ///
    /// A `UIScrollView`'s box is its viewport; the extent it can scroll over
    /// lives in `contentSize`, a property with no view of its own and therefore
    /// no line in a hierarchy dump. Two sides can agree on every frame in the
    /// tree — the tags-list screen does, at epsilon 0 — while one of them holds
    /// a content extent the other does not, and the only visible consequence is
    /// a scroller UIKit installs lazily for the axis it believes can move.
    ///
    /// That is the tags-list residue's one structural difference: the
    /// interpreted list carries a HORIZONTAL `_UIScrollerImpContainerView` the
    /// twin never installs, at y=705 — below a 700-tall capture, hidden, opacity
    /// 0, painting nothing. It still costs, because its indicator artwork takes
    /// texture-atlas cells ahead of the chart surfaces, and every `TagChartView`
    /// is consequently sampled from a cell one position along (measured:
    /// interp(row i) == twin(row i+1) across all eight rows). A `contentsRect`
    /// origin one cell over lands a few boundary pixels 1-2 LSB apart.
    ///
    /// Whether that indicator is an interpreter layout divergence or a
    /// harness-shape artifact is exactly the question `contentSize` answers and
    /// nothing already dumped can: if the interpreted content extent is wider
    /// than its viewport and the twin's is not, the two sides genuinely laid the
    /// list out to different widths. So this prints the numbers UIKit decides
    /// on and stops there — no derived "scrollable" verdict. The instrument that
    /// concluded rather than measured is the one this lane just had to correct.
    private static func scroll(of view: UIView) -> [String] {
        guard let scrollView = view as? UIScrollView else { return [] }
        // `contentSize` always prints: it is the quantity this category exists
        // to report, and there is no default value for it to be compared
        // against. Everything below follows the dump's standing rule and
        // prints only when it is NOT at its default, so a settled capture
        // stays readable — and `tree-diff.rb` still catches a divergence
        // either way, since a flag present on one side alone is a flag
        // difference.
        var parts = [
            "contentSize=(\(number(scrollView.contentSize.width)),"
                + "\(number(scrollView.contentSize.height)))"
        ]
        if scrollView.contentOffset != .zero {
            parts.append(
                "contentOffset=(\(number(scrollView.contentOffset.x)),"
                    + "\(number(scrollView.contentOffset.y)))")
        }
        // The adjusted inset, not the raw one: the adjusted value is what the
        // viewport is actually reduced by, and it is what the overflow
        // comparison is made against.
        let inset = scrollView.adjustedContentInset
        if inset != .zero {
            parts.append(
                "adjustedInset=(\(number(inset.top)),\(number(inset.left)),"
                    + "\(number(inset.bottom)),\(number(inset.right)))")
        }
        // Same rule as the rest of the dump — only non-default state. Both
        // indicator flags default to true, so a printed one means a side
        // suppressed it.
        if !scrollView.showsHorizontalScrollIndicator {
            parts.append("noHorizontalIndicator")
        }
        if !scrollView.showsVerticalScrollIndicator {
            parts.append("noVerticalIndicator")
        }
        return parts
    }

    private static func rect(_ value: CGRect) -> String {
        "(\(number(value.minX)),\(number(value.minY)),"
            + "\(number(value.width)),\(number(value.height)))"
    }

    /// A colour, in its OWN space and at full precision. Converting to sRGB
    /// first would hide exactly the difference this is looking for: the scored
    /// PNG is Display P3 and the compositing destination is float extended
    /// sRGB, so two colours that differ in the fourth decimal of one component
    /// can round to the same 8-bit sRGB triple and read as identical.
    private static func color(_ value: CGColor) -> String {
        let components = (value.components ?? []).map { number($0) }
        let space = (value.colorSpace?.name as String?) ?? "unnamed"
        return "[\(space) \(components.joined(separator: ","))]"
    }

    /// What a layer contributes to a blend, as opposed to where it sits.
    ///
    /// Geometry, coverage state and the destination bitmap are all measured
    /// above, so a residue that survives them is a difference in the VALUES
    /// being combined — and until this existed the dump could show two sides
    /// as byte-identical while they filled and stroked in different colours.
    /// A 1-point border is the case that makes it matter: at capture scale 1
    /// every pixel of it is a partial-coverage blend, so a hairline whose
    /// alpha differs slightly produces no flat differing region at all, only
    /// antialiased edges a level or two apart — indistinguishable, without
    /// this, from a sub-pixel geometry shift.
    private static func paint(of layer: CALayer) -> [String] {
        var parts: [String] = []
        if let background = layer.backgroundColor {
            parts.append("bg=\(color(background))")
        }
        // Reported whenever a border is actually drawn: a zero-width border
        // keeps whatever colour it was last assigned, and printing that would
        // invent a difference on a layer that strokes nothing.
        if layer.borderWidth != 0, let border = layer.borderColor {
            parts.append("borderColor=\(color(border))")
        }
        // A shadow darkens pixels OUTSIDE the shape it belongs to, which is
        // the same place an antialiased edge lives.
        if layer.shadowOpacity != 0 {
            parts.append("shadowOpacity=\(number(CGFloat(layer.shadowOpacity)))")
            parts.append("shadowRadius=\(number(layer.shadowRadius))")
            parts.append(
                "shadowOffset=(\(number(layer.shadowOffset.width)),"
                    + "\(number(layer.shadowOffset.height)))")
            if let shadow = layer.shadowColor {
                parts.append("shadowColor=\(color(shadow))")
            }
        }
        if let shape = layer as? CAShapeLayer {
            if let stroke = shape.strokeColor {
                parts.append("strokeColor=\(color(stroke))")
            }
            if let fill = shape.fillColor {
                parts.append("fillColor=\(color(fill))")
            }
        }
        return parts
    }

    /// The `@raster` line: the BITMAP the board scores, described by the
    /// context that actually drew it rather than by the code that asked for
    /// it. Both harnesses build their format with the same four statements
    /// (`UIGraphicsImageRendererFormat()`, `scale = 1`, `opaque = false`), so
    /// reading the source says they agree — but `preferredRange` defaults to
    /// `.automatic`, which is RESOLVED at render time against the display and
    /// the trait environment, and the resolved value decides the context's
    /// colour space and bit depth. Identical source, two processes, possibly
    /// two blend spaces.
    ///
    /// That is worth an instrument because it is the exact shape of the
    /// media residue: compositing space changes only pixels that are BLENDED,
    /// so a flat interior stays byte-identical while every antialiased
    /// boundary moves a level or two — which is what the board measures
    /// (3410 px, 100% on a twin edge, max 2/255, over a byte-identical tree).
    /// Layout, placement and coverage state are already ruled out by the
    /// three sections above; how the destination bitmap composites is the
    /// remaining variable, and nothing in the tree can express it.
    ///
    /// Deliberately carries no bare `x`/`y`/`w`/`h` key, so `tree-diff.rb`
    /// skips it exactly as it skips `@capture`: this describes the canvas,
    /// not a node on it.
    private static func raster(
        format: UIGraphicsImageRendererFormat, product: UIImage
    ) -> String {
        var parts = [
            "@raster",
            "formatScale=\(number(format.scale))",
            "opaque=\(format.opaque)",
            // `.automatic` is 0, and it STAYS 0 here: the format object is the
            // one the caller configured, so this reports the request. What the
            // request resolved to is only legible in the product below.
            "preferredRange=\(format.preferredRange.rawValue)",
        ]
        // The destination is described through the produced image and not
        // through the renderer's `cgContext`, which was tried first and is a
        // dead end worth naming so nobody re-adds it: under Catalyst that
        // context reports bitsPerComponent 0, bitsPerPixel 0 and a nil colour
        // space, because `drawHierarchy` composites through the window server
        // rather than into a bitmap context the caller can inspect. The
        // product is the actual scored bitmap and answers the same question.
        parts.append("productScale=\(number(product.scale))")
        guard let image = product.cgImage else {
            parts.append("product=none")
            return parts.joined(separator: " ")
        }
        parts.append("productPixels=\(image.width)x\(image.height)")
        parts.append("bitsPerComponent=\(image.bitsPerComponent)")
        parts.append("bitsPerPixel=\(image.bitsPerPixel)")
        if let space = image.colorSpace {
            parts.append("space=\((space.name as String?) ?? "unnamed")")
            parts.append("spaceModel=\(space.model.rawValue)")
            parts.append("spaceComponents=\(space.numberOfComponents)")
        } else {
            parts.append("space=none")
        }
        parts.append("alphaInfo=\(image.alphaInfo.rawValue)")
        parts.append("bitmapInfo=\(image.bitmapInfo.rawValue)")
        // A float-component destination blends coverage at a precision an
        // integer one rounds away, which is a sub-level difference per edge.
        if image.bitmapInfo.contains(.floatComponents) {
            parts.append("floatComponents")
        }
        parts.append("renderingIntent=\(image.renderingIntent.rawValue)")
        return parts.joined(separator: " ")
    }

    /// Set by `record`, emitted by `write`.
    ///
    /// The indirection is what lets ONE shared file serve two harnesses that
    /// rasterize on opposite sides of their dump: the context that can answer
    /// the question does not outlive the renderer block, and neither harness
    /// should have to know when the other writes. `record` is pure and
    /// I/O-free, so it is safe to call from inside the block on either side;
    /// `write` is the single place the file is produced, so the line cannot
    /// be half-appended or clobbered by the tree that follows it.
    /// `nonisolated(unsafe)` is accurate rather than a waiver: both harnesses
    /// capture on the main actor, one screen per process, and the dump is off
    /// unless `ICECUBES_DUMP_TREE` asks for it.
    nonisolated(unsafe) private static var pendingRaster: String?

    /// Records how the destination bitmap composites. Call right after the
    /// renderer returns, where both the format and the product are in scope.
    /// Calling it repeatedly is fine — a harness that rasterizes until two
    /// passes agree records once per pass, and the accepted one is last.
    static func record(
        format: UIGraphicsImageRendererFormat, product: UIImage
    ) {
        guard isEnabled else { return }
        pendingRaster = raster(format: format, product: product)
    }

    /// Writes the dump next to the capture. Failures are silent by design:
    /// an instrument that can fail a scored capture is a liability, and the
    /// missing file is its own signal.
    static func write(
        captureView: UIView, screen: String, directory: String
    ) {
        guard isEnabled else { return }
        var lines: [String] = [placement(of: captureView)]
        if let pendingRaster { lines.append(pendingRaster) }
        walk(captureView, in: captureView, depth: 0, into: &lines)
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(screen).tree")
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
