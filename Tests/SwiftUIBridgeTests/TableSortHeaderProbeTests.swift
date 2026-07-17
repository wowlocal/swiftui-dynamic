import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// The orders-screen root cause: the Table gateway dropped the app's
// `sortOrder:` binding, so the sorted column's native header treatment
// (bold title + sort-direction chevron) never rendered. The gateway now
// translates the binding into real sortable TableColumns; the sorted
// column and direction come from the app's KeyPathComparator array.
@Suite struct TableSortHeaderProbeTests {
    nonisolated struct NItem: Identifiable {
        let id: Int
        let name: String
        let score: Int
    }

    @MainActor
    @Test func sortedColumnHeaderMatchesNative() throws {
        let source = """
        struct Item: Identifiable {
            let id: Int
            let name: String
            let score: Int
        }

        @main
        struct P: App {
            @State private var sortOrder = [KeyPathComparator(\\Item.score, order: .reverse)]
            var items: [Item] {
                [Item(id: 1, name: String("Alpha"), score: 30),
                 Item(id: 2, name: String("Beta"), score: 10),
                 Item(id: 3, name: String("Gamma"), score: 20)]
                .sorted(using: sortOrder)
            }
            var body: some Scene {
                WindowGroup {
                    Table(items, sortOrder: $sortOrder) {
                        TableColumn("Name", value: \\.name) { item in
                            Text(item.name)
                        }
                        TableColumn("Score", value: \\.score) { item in
                            Text(String(item.score))
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
        let size = NSSize(width: 400, height: 160)
        let interp = Self.bitmap(view, size: size)
        let comparators = [KeyPathComparator(\NItem.score, order: SortOrder.reverse)]
        let rows = [
            NItem(id: 1, name: "Alpha", score: 30),
            NItem(id: 2, name: "Beta", score: 10),
            NItem(id: 3, name: "Gamma", score: 20),
        ].sorted(using: comparators)
        let native = Self.bitmap(AnyView(
            Table(rows, sortOrder: .constant(comparators)) {
                TableColumn("Name", value: \.name) { item in
                    Text(item.name)
                }
                TableColumn("Score", value: \.score) { item in
                    Text(String(item.score))
                }
            }
        ), size: size)
        var mismatched = 0
        for x in 0..<400 {
            for y in 0..<160 {
                let a = interp.colorAt(x: x, y: y)
                let b = native.colorAt(x: x, y: y)
                if let a, let b, abs(a.redComponent - b.redComponent) > 0.02 {
                    mismatched += 1
                }
            }
        }
        print("PROBE table-sort-header mismatched:", mismatched)
        #expect(mismatched == 0)
    }

    @MainActor
    static func bitmap(_ view: AnyView, size: NSSize) -> NSBitmapImageRep {
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
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("no rep")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }
}
