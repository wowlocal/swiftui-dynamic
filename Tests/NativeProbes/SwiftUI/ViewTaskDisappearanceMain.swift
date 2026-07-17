import AppKit
import Foundation
import SwiftUI

@main
struct ViewTaskDisappearanceMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()

        let hostingView = NSHostingView(
            rootView: AnyView(SwiftUIViewTaskCancellationProbe()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()

        let startDeadline = Date().addingTimeInterval(2)
        while swiftUIViewTaskCancellationEvents.isEmpty
            && Date() < startDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        hostingView.rootView = AnyView(EmptyView())
        let cancellationDeadline = Date().addingTimeInterval(2)
        while swiftUIViewTaskCancellationEvents.count < 2
            && Date() < cancellationDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        print(swiftUIViewTaskCancellationEvents.joined(separator: ","))
        window.close()
    }
}
