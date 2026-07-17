import AppKit
import Foundation
import SwiftUI

@main
struct ViewTaskSameIDMain {
    @MainActor
    private static func pump(
        until condition: () -> Bool,
        timeout: TimeInterval = 2
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.finishLaunching()

        let hostingView = NSHostingView(
            rootView: AnyView(SwiftUIViewTaskSameIDProbe(
                id: 7, generation: "first")))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()

        pump {
            swiftUIViewTaskSameIDEvents.contains("render:first")
                && swiftUIViewTaskSameIDEvents.contains("start:first")
        }
        hostingView.rootView = AnyView(SwiftUIViewTaskSameIDProbe(
            id: 7, generation: "same"))
        pump { swiftUIViewTaskSameIDEvents.contains("render:same") }

        // Releasing only after SwiftUI has processed the same-id update makes
        // the completing generation a causal observation of which task lived.
        swiftUIViewTaskSameIDRelease = true
        pump {
            swiftUIViewTaskSameIDEvents.contains { event in
                event.hasPrefix("finish:") || event.hasPrefix("error:")
            }
        }

        hostingView.rootView = AnyView(EmptyView())
        pump {
            !swiftUIViewTaskSameIDEvents.contains { event in
                event.hasPrefix("start:") && event != "start:first"
            }
        }
        window.close()

        print(swiftUIViewTaskSameIDEvents.sorted().joined(separator: ","))
    }
}
