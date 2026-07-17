import AppKit
import Foundation
import SwiftUI

@main
struct ViewTaskIDReplacementMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()

        let hostingView = NSHostingView(
            rootView: AnyView(SwiftUIViewTaskIDProbe(id: 1)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()

        let firstDeadline = Date().addingTimeInterval(2)
        while !swiftUIViewTaskIDEvents.contains("start:1")
            && Date() < firstDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        hostingView.rootView = AnyView(SwiftUIViewTaskIDProbe(id: 2))
        let replacementDeadline = Date().addingTimeInterval(2)
        while (!swiftUIViewTaskIDEvents.contains("cancel:1")
            || !swiftUIViewTaskIDEvents.contains("start:2"))
            && Date() < replacementDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        hostingView.rootView = AnyView(EmptyView())
        let removalDeadline = Date().addingTimeInterval(2)
        while !swiftUIViewTaskIDEvents.contains("cancel:2")
            && Date() < removalDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        print(swiftUIViewTaskIDEvents.sorted().joined(separator: ","))
        window.close()
    }
}
