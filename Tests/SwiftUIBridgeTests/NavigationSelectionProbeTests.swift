import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// The R4 sidebar-navigation root cause: the List gateway DROPPED the
// `selection:` binding and bridged NavigationLink rows carried no tags, so
// a live click could highlight a row but never write the interpreted
// selection state — the detail panel froze. Rows now tag with their
// stringified identity, NavigationSelectionValues maps tags back to the
// ORIGINAL runtime values, and the binding writes through the state box.
@Suite struct NavigationSelectionProbeTests {
    @MainActor
    @Test func sidebarSelectionWritesInterpretedStateAndSwapsDetail() throws {
        let source = """
        enum Panel: String, CaseIterable {
            case truck
            case orders
        }

        @main
        struct P: App {
            @State private var selection: Panel? = Panel.truck
            var body: some Scene {
                WindowGroup {
                    HStack(spacing: 0) {
                        List(selection: $selection) {
                            NavigationLink(value: Panel.truck) {
                                Label(String("Truck"), systemImage: String("box.truck"))
                            }
                            NavigationLink(value: Panel.orders) {
                                Label(String("Orders"), systemImage: String("shippingbox"))
                            }
                        }
                        .frame(width: 180)
                        switch selection {
                        case .orders:
                            Text(String("ORDERS PANEL"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        default:
                            Text(String("TRUCK PANEL"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success(let view) = rendered else {
            Issue.record("render failed")
            return
        }
        // The rows registered their selection values at construction.
        #expect(!NavigationSelectionValues.byTag.isEmpty)

        let size = NSSize(width: 420, height: 200)
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        let before = Self.bitmap(hosting)
        // Find the list's table and select the Orders row through AppKit —
        // from here the chain matches a live click: AppKit selection →
        // SwiftUI binding → interpreted state write → detail re-render.
        let probe = NSPoint(x: 90, y: hosting.isFlipped ? 30 : hosting.bounds.height - 30)
        var ancestor: NSView? = hosting.hitTest(probe)
        while let current = ancestor, !(current is NSTableView) { ancestor = current.superview }
        guard let table = ancestor as? NSTableView else {
            Issue.record("no sidebar table found")
            return
        }
        #expect(table.numberOfRows == 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let after = Self.bitmap(hosting)
        var mismatched = 0
        for x in 200..<Int(size.width) {
            for y in 0..<Int(size.height) {
                let a = before.colorAt(x: x, y: y)
                let b = after.colorAt(x: x, y: y)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE navigation-selection detail-changed:", mismatched)
        // The detail region must repaint (TRUCK PANEL → ORDERS PANEL).
        #expect(mismatched > 50)
        // The SIDEBAR must survive the re-render: the live sweep found the
        // list column blanking to the canvas after a selection write.
        var sidebarInk = 0
        for x in 0..<180 {
            for y in 0..<Int(size.height) {
                if let color = after.colorAt(x: x, y: y), color.brightnessComponent < 0.9 {
                    sidebarInk += 1
                }
            }
        }
        print("PROBE navigation-selection sidebar-ink:", sidebarInk)
        #expect(sidebarInk > 200)
    }

    @MainActor
    static func bitmap(_ view: NSView) -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("no rep")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
