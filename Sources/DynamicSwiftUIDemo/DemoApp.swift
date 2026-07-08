import AppKit
import SwiftUI

@main
struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Dynamic SwiftUI") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

/// `swift run` executables have no app bundle, so AppKit launches them as
/// background processes — without this activation dance no window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
