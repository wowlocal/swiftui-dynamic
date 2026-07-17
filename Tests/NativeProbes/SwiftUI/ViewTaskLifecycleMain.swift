import AppKit
import Foundation
import SwiftUI

@main
struct ViewTaskLifecycleMain {
    @MainActor
    private static func host(
        _ view: AnyView
    ) -> (NSHostingView<AnyView>, NSWindow) {
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        return (hostingView, window)
    }

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

        let (_, entryWindow) = host(
            AnyView(SwiftUIViewTaskRuntimeEntryProbe()))
        pump { swiftUIViewTaskEvents.count == 2 }
        let entry = swiftUIViewTaskEvents.joined(separator: ",")
        entryWindow.close()

        let (cancellationHost, cancellationWindow) = host(
            AnyView(SwiftUIViewTaskCancellationProbe()))
        pump { swiftUIViewTaskCancellationEvents.contains("started") }
        cancellationHost.rootView = AnyView(EmptyView())
        pump { swiftUIViewTaskCancellationEvents.contains("cancelled") }
        let disappearance = swiftUIViewTaskCancellationEvents
            .joined(separator: ",")
        cancellationWindow.close()

        let (idHost, idWindow) = host(
            AnyView(SwiftUIViewTaskIDProbe(id: 1)))
        pump { swiftUIViewTaskIDEvents.contains("start:1") }
        idHost.rootView = AnyView(SwiftUIViewTaskIDProbe(id: 2))
        pump {
            swiftUIViewTaskIDEvents.contains("cancel:1")
                && swiftUIViewTaskIDEvents.contains("start:2")
        }
        idHost.rootView = AnyView(EmptyView())
        pump { swiftUIViewTaskIDEvents.contains("cancel:2") }
        let replacement = swiftUIViewTaskIDEvents.sorted()
            .joined(separator: ",")
        idWindow.close()

        print("entry=\(entry)|disappearance=\(disappearance)|id=\(replacement)")
    }
}
