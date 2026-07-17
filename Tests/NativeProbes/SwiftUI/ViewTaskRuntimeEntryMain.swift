import AppKit
import Foundation
import SwiftUI

@main
struct ViewTaskRuntimeEntryMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()

        let hostingView = NSHostingView(
            rootView: SwiftUIViewTaskRuntimeEntryProbe())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()

        let deadline = Date().addingTimeInterval(2)
        while swiftUIViewTaskEvents.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        print(swiftUIViewTaskEvents.joined(separator: ","))
        window.close()
    }
}
