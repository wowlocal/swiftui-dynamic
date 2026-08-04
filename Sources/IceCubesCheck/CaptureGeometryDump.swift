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
        return parts.joined(separator: " ")
    }

    /// Writes the dump next to the capture. Failures are silent by design:
    /// an instrument that can fail a scored capture is a liability, and the
    /// missing file is its own signal.
    static func write(
        captureView: UIView, screen: String, directory: String
    ) {
        guard isEnabled else { return }
        var lines: [String] = [placement(of: captureView)]
        walk(captureView, in: captureView, depth: 0, into: &lines)
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(screen).tree")
        try? lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
