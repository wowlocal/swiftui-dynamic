import AppKit
import SwiftUI

struct Root: App {
    var body: some Scene {
        WindowGroup("Probe") {
            NavigationSplitView {
                Text("Sidebar")
            } detail: {
                DetailPane()
            }
            .frame(minWidth: 700, minHeight: 400)
            .task { await drive() }
        }
    }

    @MainActor
    func drive() async {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            print("MENULINK no-window"); exit(2)
        }
        var popup: NSPopUpButton?
        func find(_ view: NSView) {
            if popup == nil, let candidate = view as? NSPopUpButton { popup = candidate }
            view.subviews.forEach(find)
        }
        window.contentView.map(find)
        guard let popup else { print("MENULINK no-popup"); exit(2) }
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = popup.menu else { return }
                print("MENULINK items:", menu.items.map(\.title).joined(separator: "|"))
                // Self-process ACCESSIBILITY press: the assistive
                // path, allowed without grants for one's own app.
                guard let index = menu.items.firstIndex(where: { $0.title.contains("Typed") }) else {
                    menu.cancelTracking(); return
                }
                let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                func findPress(_ element: AXUIElement, depth: Int) -> Bool {
                    guard depth < 12 else { return false }
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                    if let title = titleRef as? String, title.contains("Typed") {
                        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                    }
                    var childrenRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
                    for child in (childrenRef as? [AXUIElement]) ?? [] {
                        if findPress(child, depth: depth + 1) { return true }
                    }
                    return false
                }
                let pressed = findPress(app, depth: 0)
                print("MENULINK ax-pressed=\(pressed) index=\(index)")
                if !pressed { menu.cancelTracking() }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        popup.performClick(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("MENULINK after-typed title=\"\(window.title)\"")
        // second round: the ERASED link
        let timer2 = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = popup.menu else { return }
                if let index = menu.items.firstIndex(where: { $0.title.contains("Erased") }) {
                    menu.performActionForItem(at: index)
                }
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer2, forMode: .eventTracking)
        popup.performClick(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("MENULINK after-erased title=\"\(window.title)\"")
        exit(0)
    }
}

struct DetailPane: View {
    var body: some View {
        VStack {
            Menu("Actions") {
                NavigationLink(value: "typed-dest") { Label("Typed Link", systemImage: "1.circle") }
                AnyView(NavigationLink(value: "erased-dest") { Label("Erased Link", systemImage: "2.circle") })
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .navigationTitle("Start")
        .navigationDestination(for: String.self) { value in
            Text("Pushed \(value)").navigationTitle(value)
        }
    }
}

Root.main()
