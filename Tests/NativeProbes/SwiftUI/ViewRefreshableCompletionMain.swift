import AppKit
import Foundation
import SwiftUI

@main
struct ViewRefreshableCompletionMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()

        let hostingView = NSHostingView(
            rootView: AnyView(SwiftUIRefreshableCompletionProbe()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()

        var deadline = Date().addingTimeInterval(2)
        while !swiftUIRefreshableEvents.contains("started")
            && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        guard swiftUIRefreshableEvents == ["started"] else {
            print("before-release="
                + swiftUIRefreshableEvents.joined(separator: ","))
            window.close()
            return
        }

        swiftUIRefreshableRelease = true
        deadline = Date().addingTimeInterval(2)
        while swiftUIRefreshableEvents.count < 3 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        window.close()

        print(swiftUIRefreshableEvents.joined(separator: ","))
    }
}
