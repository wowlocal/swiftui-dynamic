import AppKit
import SwiftUI

@main
struct ExpenseTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Expenses (native)") {
            ContentView()
                .frame(width: 470, height: 780)
        }
    }
}

/// Same activation dance as DynamicSwiftUIDemo: `swift run` executables have
/// no app bundle, so without this no window appears. `--render-png <path>`
/// renders the same 470x780 canvas headlessly for pixel comparison against
/// the interpreted version.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-png"),
           CommandLine.arguments.indices.contains(index + 1) {
            renderSnapshot(to: CommandLine.arguments[index + 1])
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    private func renderSnapshot(to path: String) {
        let hosting = NSHostingView(rootView: AnyView(ContentView()).padding(40).background(Color.white))
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 470, height: 780))
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
