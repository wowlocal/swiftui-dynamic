import AppKit
import AppKitFocusStudio
import SwiftUI

@main
struct AppKitFocusStudioNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Focus Studio — Native") {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            exit(0)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-png"),
           CommandLine.arguments.indices.contains(index + 1) {
            renderSnapshot(to: CommandLine.arguments[index + 1])
            exit(0)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func runSelfTest() {
        let report = AppKitFocusChecks.run()
        print("state transitions: \(report.stateTransitions ? "PASS" : "FAIL")")
        print("NSColor palette math: \(report.paletteMath ? "PASS" : "FAIL")")
        print("NSView + NSProgressIndicator: \(report.nativeGeometryAndMeter ? "PASS" : "FAIL")")
        print("NSFont + NSTextField: \(report.nativeTypographyAndText ? "PASS" : "FAIL")")
        print("NSPasteboard round-trip: \(report.nativePasteboard ? "PASS" : "FAIL")")
        print("result: \(report.passedCount)/5")
        if !report.allPassed { exit(1) }
    }

    private func renderSnapshot(to path: String) {
        let dark = argument(after: "--appearance")?.lowercased() != "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let colorScheme: ColorScheme = dark ? .dark : .light
        let size = snapshotSize()

        let hosting = NSHostingView(rootView: AnyView(
            ContentView()
                // Match DynamicSwiftUIDemo's 40-point snapshot inset even
                // when the native NSLevelIndicator asks for extra height.
                .frame(
                    width: max(1, size.width - 80),
                    height: max(1, size.height - 80),
                    alignment: .top
                )
                .environment(\.colorScheme, colorScheme)
                .padding(40)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = hosting
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        for _ in 0..<8 {
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        let captureBounds = NSRect(origin: .zero, size: size)
        hosting.frame = captureBounds

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width.rounded(.up))),
            pixelsHigh: max(1, Int(size.height.rounded(.up))),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        rep.size = size
        hosting.cacheDisplay(in: captureBounds, to: rep)
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

    private func snapshotSize() -> NSSize {
        guard let raw = argument(after: "--size") else {
            return NSSize(width: 980, height: 700)
        }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return NSSize(width: 980, height: 700)
        }
        return NSSize(width: width, height: height)
    }

    private func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }
}
