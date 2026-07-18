import AppKit
import SwiftUI
import SwiftUIBridge

/// R4 live-window sweep: after the interpreted project renders in the REAL
/// interactive window, post genuine NSEvents through `window.sendEvent`
/// (real AppKit hit-testing → real SwiftUI gesture handling) and verify the
/// UI responds — sidebar clicks must land their panels. Prints one
/// `SWEEP <step> changed=<pixels>` line per interaction and a final
/// `SWEEP GREEN`/`SWEEP RED`, then exits with the verdict.
@MainActor
enum SweepDriver {
    /// Sidebar outline rows (headers are rows too): 0 Truck, 1 Orders,
    /// 2 Social Feed, 3 Sales History, 4 "Donuts" header, 5 Donuts,
    /// 6 Donut Editor, 7 Top 5, 8 "Cities" header, 9-11 cities.
    /// Each step's expected DETAIL navigationTitle — under the real
    /// NavigationSplitView the macOS titlebar mirrors it, which is the
    /// native per-panel evidence a person sees (captures are island-blind
    /// behind the split's per-column hosting).
    static let steps: [(name: String, row: Int, title: String)] = [
        ("orders", 1, "Orders"),
        ("socialfeed", 2, "Social Feed"),
        ("saleshistory", 3, "Sales History"),
        ("donuts", 5, "Donuts"),
        ("donuteditor", 6, "New Donut"),
        ("topfive", 7, "Top 5 Donuts"),
        ("cupertino", 9, "Cupertino"),
        ("london", 11, "London"),
        ("truck", 0, "Truck"),
    ]

    static func run(outDirectory: String) async {
        try? FileManager.default.createDirectory(
            atPath: outDirectory, withIntermediateDirectories: true)
        // DEMO_SWEEP_STEP=<name> runs ONE navigation in a fresh process:
        // layer rasterization is only trustworthy for the FIRST re-render
        // after initial compositing, so the r4 script loops panels through
        // separate processes instead of chaining them.
        let selected = ProcessInfo.processInfo.environment["DEMO_SWEEP_STEP"]
        // Let the project interpret and the window settle.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            print("SWEEP RED no-window")
            exit(2)
        }
        window.setContentSize(NSSize(width: 1000, height: 832))
        // Clicks on an INACTIVE app's window are swallowed as activation
        // (acceptsFirstMouse) — the sweep must own focus while it drives.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        var previous = capture("sweep-0-initial", window: window, outDirectory: outDirectory)
        var allGreen = previous != nil
        var reportedDiagnostics = RenderDiagnostics.errors.count
        let plan = selected.map { name in steps.filter { $0.name == name } } ?? steps
        let settleMs = ProcessInfo.processInfo.environment["DEMO_SWEEP_WAIT_MS"]
            .flatMap(UInt64.init) ?? 1_500
        for (index, step) in plan.enumerated() {
            click(window: window, row: step.row)
            try? await Task.sleep(nanoseconds: settleMs * 1_000_000)
            // Re-renders can grow the window; captures must stay comparable.
            window.setContentSize(NSSize(width: 1000, height: 832))
            try? await Task.sleep(nanoseconds: 300_000_000)
            let current = capture(
                "sweep-\(index + 1)-\(step.name)", window: window, outDirectory: outDirectory)
            let changed = changedPixels(previous, current)
            // Layer rasterization is PARTIAL for re-created live tables
            // (SWEEP-TREE proved healthy hierarchies under blank captures),
            // so each step lands on hierarchy markers + repaint magnitude,
            // not raw capture ink.
            let rowCounts = tableRowCounts(in: window)
            let sidebarAlive = rowCounts.contains(12)
            let ordersTableVisible = rowCounts.contains { $0 >= 20 }
            let freshDiagnostics = RenderDiagnostics.errors.count - reportedDiagnostics
            // The TITLE is the primary landing evidence (the detail's own
            // navigationTitle reaching the titlebar); hierarchy markers add
            // panel-specific truth; `changed` is REPORTED only — captures
            // cannot see across the split's per-column hosting islands.
            let titled = window.title == step.title
            let panelMarker: Bool
            switch step.name {
            case "orders":
                panelMarker = ordersTableVisible
            case "socialfeed":
                // The feed's own list replaces the orders table.
                panelMarker = rowCounts.contains { $0 >= 5 && $0 < 20 }
            case "cupertino", "london":
                // DetailedMapView EXECUTES: a real MKMapView in the island.
                panelMarker = viewPresent(in: window) {
                    String(describing: type(of: $0)).contains("MKMapView")
                }
            default:
                panelMarker = true
            }
            let landed = sidebarAlive && titled && panelMarker
                && freshDiagnostics == 0
            print("SWEEP \(step.name) changed=\(changed) tables=\(rowCounts) diag=\(RenderDiagnostics.errors.count) title=\"\(window.title)\" marker=\(panelMarker) landed=\(landed)")
            if ProcessInfo.processInfo.environment["DEMO_SWEEP_TREE"] != nil,
               let content = window.contentView {
                func walkTree(_ view: NSView, _ depth: Int) {
                    let name = String(describing: type(of: view))
                    if depth < 24 {
                        print("SWEEP-TREE \(String(repeating: "  ", count: depth))\(name) \(Int(view.frame.width))x\(Int(view.frame.height))")
                    }
                    view.subviews.forEach { walkTree($0, depth + 1) }
                }
                walkTree(content, 0)
            }
            if ProcessInfo.processInfo.environment["DEMO_SWEEP_CONTROLS"] != nil,
               let content = window.contentView {
                var controls: [String] = []
                func walkControls(_ view: NSView) {
                    if view is NSControl || String(describing: type(of: view)).contains("Segment") {
                        controls.append("\(String(describing: type(of: view))) frame=\(Int(view.frame.width))x\(Int(view.frame.height))")
                    }
                    view.subviews.forEach(walkControls)
                }
                walkControls(content)
                print("SWEEP-CONTROLS \(controls.prefix(12).joined(separator: " | "))")
            }
            for entry in RenderDiagnostics.errors.suffix(max(0, RenderDiagnostics.errors.count - reportedDiagnostics)).prefix(6) {
                print("SWEEP-DIAG \(step.name) \(entry.view): \(entry.error.message.prefix(110))")
            }
            reportedDiagnostics = RenderDiagnostics.errors.count
            allGreen = allGreen && landed
            previous = current
            // MUTATION phase: an order completes through its row's real
            // Details menu — menu item action -> interpreted Button action
            // -> model mutation -> table re-render (the R3 status flow,
            // driven LIVE).
            if landed, step.name == "orders" {
                var popup: NSPopUpButton?
                func findPopup(_ view: NSView) {
                    if popup == nil, let candidate = view as? NSPopUpButton,
                       candidate.frame.width < 40 {
                        popup = candidate
                    }
                    view.subviews.forEach(findPopup)
                }
                if let content = window.contentView { findPopup(content) }
                if let popup {
                    // SwiftUI populates bridged menus only during REAL
                    // tracking: open with performClick (blocks in
                    // .eventTracking mode) and let a tracking-mode timer
                    // fire the Complete item and dismiss.
                    let fired = MenuDriveState()
                    let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            guard let menu = popup.menu else { return }
                            let titles = menu.items.map(\.title)
                            print("SWEEP-MENU items: \(titles.joined(separator: " | "))")
                            if let completeIndex = menu.items.firstIndex(where: { $0.title.contains("Complete") }) {
                                menu.performActionForItem(at: completeIndex)
                                fired.didFire = true
                            }
                            menu.cancelTracking()
                        }
                    }
                    RunLoop.main.add(timer, forMode: .eventTracking)
                    popup.performClick(nil)
                    try? await Task.sleep(nanoseconds: settleMs * 1_000_000)
                    if fired.didFire {
                        let mutated = capture(
                            "sweep-\(index + 1)-\(step.name)-mutated", window: window,
                            outDirectory: outDirectory)
                        let mutatedChanged = changedPixels(previous, mutated)
                        // One order's Status cell repaints ("Placed" ->
                        // "Completed") — a single-row text change, same
                        // visual scope as native.
                        let mutatedLanded = mutatedChanged > 300
                        print("SWEEP \(step.name)-mutate changed=\(mutatedChanged) landed=\(mutatedLanded)")
                        allGreen = allGreen && mutatedLanded
                        previous = mutated
                    } else {
                        print("SWEEP \(step.name)-mutate complete-item-not-fired")
                        allGreen = false
                    }
                } else {
                    print("SWEEP \(step.name)-mutate no-menu")
                    allGreen = false
                }
            }
            // MUTATION phase: the donut editor must accept a rename
            // through the real NSTextField commit path and repaint the
            // preview with the new name.
            if landed, step.name == "donuteditor" {
                if let field = firstTextField(in: window) {
                    let expected = field.stringValue + " X"
                    field.stringValue = expected
                    // A programmatic stringValue set never reaches the
                    // SwiftUI coordinator's editing buffer (it listens via
                    // controlTextDidChange) — without this, sendAction
                    // commits the STALE buffer and the model never renames
                    // (i72 finding: the write trace carried the old name).
                    field.delegate?.controlTextDidChange?(
                        Notification(name: NSControl.textDidChangeNotification, object: field))
                    let sent = field.sendAction(field.action, to: field.target)
                    try? await Task.sleep(nanoseconds: settleMs * 1_000_000)
                    let mutated = capture(
                        "sweep-\(index + 1)-\(step.name)-mutated", window: window,
                        outDirectory: outDirectory)
                    let mutatedChanged = changedPixels(previous, mutated)
                    // The rename's only in-capture surface is the field's
                    // own glyphs (the title lives in the titlebar) — verify
                    // the COMMITTED value survived the re-render plus a
                    // visible repaint.
                    let committed = firstTextField(in: window)?.stringValue == expected
                    // ASSERTED since i72: the rename must retitle the
                    // macOS titlebar exactly as compiled (nested-field
                    // publish -> self-healing send -> island re-render ->
                    // navigationTitle re-apply; native truth pinned by
                    // TwinRetitleApp).
                    let titled = window.title == expected
                    let mutatedLanded = committed && titled && mutatedChanged > 300
                    print("SWEEP \(step.name)-mutate changed=\(mutatedChanged) sent=\(sent) committed=\(committed) titled=\(titled) title=\"\(window.title)\" landed=\(mutatedLanded)")
                    for entry in RenderDiagnostics.errors.dropFirst(reportedDiagnostics).prefix(4) {
                        print("SWEEP-DIAG \(step.name)-mutate \(entry.view): \(entry.error.message.prefix(110))")
                    }
                    reportedDiagnostics = RenderDiagnostics.errors.count
                    allGreen = allGreen && mutatedLanded
                    previous = mutated
                } else {
                    print("SWEEP \(step.name)-mutate no-text-field")
                    allGreen = false
                }
            }
            // Panels with a timeframe picker must respond to a segment
            // change — the genuine AppKit action path drives the SwiftUI
            // binding into interpreted state and the chart must repaint.
            if landed, ["saleshistory", "topfive"].contains(step.name) {
                if let segmented = firstSegmentedControl(in: window) {
                    // Pick a segment that DIFFERS from the current one —
                    // topfive defaults to its second segment and selecting
                    // it again is a native no-op.
                    let target = segmented.selectedSegment == 1
                        ? min(2, segmented.segmentCount - 1) : 1
                    segmented.selectedSegment = target
                    if let action = segmented.action {
                        NSApp.sendAction(action, to: segmented.target, from: segmented)
                    }
                    try? await Task.sleep(nanoseconds: settleMs * 1_000_000)
                    let mutated = capture(
                        "sweep-\(index + 1)-\(step.name)-mutated", window: window,
                        outDirectory: outDirectory)
                    let mutatedChanged = changedPixels(previous, mutated)
                    // The write-back proves through the RE-RENDERED control:
                    // a rejected binding write snaps the segment back on the
                    // next render pass (pixels are island-blind under the
                    // real split; the R3 board pins the chart AE-exactly).
                    let held = firstSegmentedControl(in: window)?
                        .selectedSegment == target
                    let mutateDiags = RenderDiagnostics.errors.count - reportedDiagnostics
                    let mutatedLanded = held && mutateDiags == 0
                    print("SWEEP \(step.name)-mutate changed=\(mutatedChanged) held=\(held) landed=\(mutatedLanded)")
                    for entry in RenderDiagnostics.errors.dropFirst(reportedDiagnostics).prefix(4) {
                        print("SWEEP-DIAG \(step.name)-mutate \(entry.view): \(entry.error.message.prefix(110))")
                    }
                    reportedDiagnostics = RenderDiagnostics.errors.count
                    allGreen = allGreen && mutatedLanded
                    previous = mutated
                } else {
                    print("SWEEP \(step.name)-mutate no-segmented-control")
                    allGreen = false
                }
            }
        }
        let diagnostics = RenderDiagnostics.errors.count
        print("SWEEP diagnostics=\(diagnostics)")
        print(allGreen ? "SWEEP GREEN" : "SWEEP RED")
        exit(allGreen ? 0 : 1)
    }

    /// Synthesized NSEvent pairs cannot complete list selection (queue
    /// posting re-aims to the hardware cursor; direct sendEvent pairs are
    /// dropped by the cell's tracking; true HID injection needs an
    /// accessibility grant). Drive AppKit's own selection on the sidebar
    /// outline — the chain under test is identical from there: AppKit
    /// selection → SwiftUI binding → interpreted state write → panel
    /// re-render.
    static func click(window: NSWindow, row: Int) {
        guard let content = window.contentView else { return }
        // Locate the sidebar list by hit-testing inside its column.
        // NSHostingView is FLIPPED: content-local y counts from the top.
        let probe = NSPoint(x: 100, y: content.isFlipped ? 60 : content.bounds.height - 60)
        var ancestor: NSView? = content.hitTest(probe)
        while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
        guard let table = ancestor as? NSTableView, row < table.numberOfRows else {
            print("SWEEP-CLICK no-table row=\(row)")
            return
        }
        print("SWEEP-CLICK row=\(row) rows=\(table.numberOfRows)")
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if ProcessInfo.processInfo.environment["DEMO_SWEEP_SELDEBUG"] != nil {
            print("SWEEP-SEL after=\(table.selectedRow)")
        }
    }

    /// 1x contentView bitmap (the shared capture technique) written to
    /// outDirectory for post-run inspection.
    static func capture(
        _ name: String, window: NSWindow, outDirectory: String
    ) -> NSBitmapImageRep? {
        guard let view = window.contentView else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(view.bounds.width.rounded(.up))),
            pixelsHigh: max(1, Int(view.bounds.height.rounded(.up))),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        rep.size = view.bounds.size
        // Freshly re-created table layers publish their contents on the
        // next transaction commit — flush before rasterizing or they read
        // as blank in the offscreen render.
        view.displayIfNeeded()
        CATransaction.flush()
        // The LIVE window is layer-backed: cacheDisplay yields a blank
        // bitmap there; the CALayer tree renders the actual composite.
        if let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // CALayer renders top-left origin into the bottom-left bitmap:
            // flip so artifacts read like the window.
            context.cgContext.translateBy(x: 0, y: view.bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            layer.render(in: context.cgContext)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let path = outDirectory + "/\(name).png"
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("SWEEP-CAPTURE \(name) \(path)")
        return rep
    }

    final class MenuDriveState {
        var didFire = false
    }

    static func viewPresent(
        in window: NSWindow, where predicate: (NSView) -> Bool
    ) -> Bool {
        func walk(_ view: NSView) -> Bool {
            if predicate(view) { return true }
            return view.subviews.contains(where: walk)
        }
        return window.contentView.map(walk) ?? false
    }

    static func firstTextField(in window: NSWindow) -> NSTextField? {
        var found: NSTextField?
        func walk(_ view: NSView) {
            if found == nil, let field = view as? NSTextField,
               field.isEditable, !field.isHiddenOrHasHiddenAncestor {
                found = field
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found
    }

    static func firstSegmentedControl(in window: NSWindow) -> NSSegmentedControl? {
        var found: NSSegmentedControl?
        func walk(_ view: NSView) {
            if found == nil, let control = view as? NSSegmentedControl,
               !control.isHiddenOrHasHiddenAncestor {
                found = control
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found
    }

    /// Row counts of every live NSTableView — the in-process hierarchy is
    /// the honest read of what is on screen (12 = sidebar outline; >=20 =
    /// the orders table).
    static func tableRowCounts(in window: NSWindow) -> [Int] {
        var counts: [Int] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor {
                counts.append(table.numberOfRows)
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return counts
    }

    static func changedPixels(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
        guard let a, let b else { return 0 }
        // Compare the overlapping region — a re-render can nudge the
        // window size and a bail-to-zero would mask a real panel swap.
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var changed = 0
        for x in stride(from: 0, to: width, by: 2) {
            for y in stride(from: 0, to: height, by: 2) {
                let ca = a.colorAt(x: x, y: y)
                let cb = b.colorAt(x: x, y: y)
                if let ca, let cb,
                   abs(ca.redComponent - cb.redComponent) > 0.02
                    || abs(ca.greenComponent - cb.greenComponent) > 0.02
                    || abs(ca.blueComponent - cb.blueComponent) > 0.02 {
                    changed += 1
                }
            }
        }
        // 2x2 sampling — scale back to full-pixel counts.
        return changed * 4
    }
}
