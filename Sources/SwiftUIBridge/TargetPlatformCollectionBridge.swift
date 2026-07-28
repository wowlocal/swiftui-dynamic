import SwiftUI
import SwiftInterpreter

/// SwiftUI interfaces describe collection constructors and row-inset
/// modifiers, but not the platform-owned baseline outside those row insets.
/// A macOS host adds a horizontal scroll-content margin that compiled Catalyst
/// lists do not. Apply the selected target's baseline at the
/// collection boundary so every row keeps its interface-declared inset.
///
/// This is the first instance of the target-platform scroll-collection
/// baseline pattern. It is a narrowly documented SwiftUI-magic primitive:
/// dispatch is on immutable target identity, not on an app, source type,
/// modifier spelling, row value, or literal from interpreted source.
enum TargetPlatformCollectionBridge {
    @MainActor
    static func apply(
        to rows: [AnyView], context: EvalContext
    ) -> [AnyView] {
#if os(macOS)
        guard context.buildConfiguration.targetEnvironment == "macCatalyst"
        else {
            return rows
        }
        return rows.map { row in
            AnyView(row.background(TargetPlatformListRowSeparatorAdapter()))
        }
#else
        return rows
#endif
    }

    @MainActor
    static func apply(
        to collection: AnyView, context: EvalContext
    ) -> AnyView {
#if os(macOS)
        guard context.buildConfiguration.targetEnvironment == "macCatalyst"
        else {
            return collection
        }
        // Native `ListRowGeometryProbe`: Catalyst x=20; macOS host x=28.
        let macOSScrollCollectionHorizontalBaseline: CGFloat = 8
        return AnyView(collection.padding(
            .horizontal, -macOSScrollCollectionHorizontalBaseline))
#else
        return collection
#endif
    }
}

#if os(macOS)
/// A compiled Catalyst plain list owns a 20-point trailing separator baseline
/// independently of `listRowInsets`. macOS SwiftUI instead lets its AppKit row
/// separator run to the visible collection edge. The swiftinterface exposes
/// neither platform-owned baseline, so a row-local representable clips the
/// host separator after SwiftUI has resolved visibility, tint, and the
/// semantic leading alignment guide.
///
/// This is the second facet of the existing target-platform collection
/// primitive, not a per-API gateway: it applies uniformly to every interpreted
/// row selected for a Catalyst target. It locates the AppKit-owned separator by
/// structural properties (a full-row, leaf sibling outside the hosted content
/// branch), never by a private class or source/API identity.
private struct TargetPlatformListRowSeparatorAdapter: NSViewRepresentable {
    func makeNSView(context: Context) -> TargetPlatformListRowSeparatorView {
        TargetPlatformListRowSeparatorView()
    }

    func updateNSView(
        _ nsView: TargetPlatformListRowSeparatorView, context: Context
    ) {
        nsView.updateSeparatorMask()
    }
}

private final class TargetPlatformListRowSeparatorView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateSeparatorMask()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSeparatorMask()
    }

    override func layout() {
        super.layout()
        updateSeparatorMask()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func updateSeparatorMask() {
        var ancestor = superview
        while let view = ancestor, !(view is NSTableRowView) {
            ancestor = view.superview
        }
        guard let row = ancestor as? NSTableRowView else {
            return
        }

        var contentBranch: NSView = self
        while let parent = contentBranch.superview, parent !== row {
            contentBranch = parent
        }
        guard contentBranch.superview === row else {
            return
        }

        let visible = row.visibleRect
        let targetTrailingBaseline: CGFloat = 20
        guard visible.width > targetTrailingBaseline else {
            return
        }
        let clip: NSRect
        if row.userInterfaceLayoutDirection == .rightToLeft {
            clip = NSRect(
                x: visible.minX + targetTrailingBaseline,
                y: row.bounds.minY,
                width: visible.width - targetTrailingBaseline,
                height: row.bounds.height)
        } else {
            clip = NSRect(
                x: visible.minX,
                y: row.bounds.minY,
                width: visible.width - targetTrailingBaseline,
                height: row.bounds.height)
        }

        let epsilon: CGFloat = 0.5
        for separator in row.subviews where separator !== contentBranch {
            guard separator.subviews.isEmpty,
                  abs(separator.frame.minX - row.bounds.minX) < epsilon,
                  abs(separator.frame.minY - row.bounds.minY) < epsilon,
                  abs(separator.frame.width - row.bounds.width) < epsilon,
                  abs(separator.frame.height - row.bounds.height) < epsilon
            else {
                continue
            }
            separator.wantsLayer = true
            let localClip = separator.convert(clip, from: row)
            let mask = CAShapeLayer()
            mask.frame = separator.bounds
            mask.path = CGPath(rect: localClip, transform: nil)
            mask.fillColor = NSColor.black.cgColor
            separator.layer?.mask = mask
            separator.needsDisplay = true
        }
    }
}
#endif
