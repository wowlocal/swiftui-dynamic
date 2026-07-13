import AppKit
import AppKitMetalSignal
import SwiftUI

@main
struct AppKitMetalSignalNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Metal Signal Lab — Native") {
            ContentView()
                .frame(minWidth: 1_080, minHeight: 720)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }

        if let path = argument(after: "--render-png") {
            renderSnapshot(to: path)
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
        do {
            let engine = try MetalSignalEngine()
            let frames = try MetalSignalPattern.allCases.map { pattern in
                try engine.render(
                    width: 320,
                    height: 200,
                    pattern: pattern,
                    phase: 0.18,
                    scale: 1.15
                )
            }
            let repeatFrame = try engine.render(
                width: 320,
                height: 200,
                pattern: .aurora,
                phase: 0.18,
                scale: 1.15
            )
            let shiftedFrame = try engine.render(
                width: 320,
                height: 200,
                pattern: .aurora,
                phase: 0.63,
                scale: 1.15
            )
            let first = frames[0]
            let exportURL = URL(fileURLWithPath: "/tmp/appkit-metal-signal-selftest.png")
            try first.pngData.write(to: exportURL)
            let exported = try Data(contentsOf: exportURL)

            let checks = [
                ("default Metal device", !engine.deviceName.isEmpty),
                ("compute shader dispatch", first.width == 320 && first.height == 200),
                ("four distinct kernels", Set(frames.map(\.checksum)).count == 4),
                ("deterministic uniforms", repeatFrame.checksum == first.checksum),
                ("phase uniform changes output", shiftedFrame.checksum != first.checksum),
                ("non-flat luminance field", first.lumaSpread > 0.35),
                ("sampled color diversity", first.distinctSamples > 100),
                ("AppKit PNG encoding", first.pngData.count > 1_000),
                ("NSImage construction", Int(first.image.size.width) == first.width
                    && Int(first.image.size.height) == first.height),
                ("export round-trip", exported == first.pngData),
            ]

            print("device: \(engine.deviceName)")
            for frame in frames {
                print(
                    "frame: patternChecksum=\(frame.checksum)"
                        + " gpuMicros=\(Int(frame.gpuMilliseconds * 1_000))"
                        + " pngBytes=\(frame.pngData.count)"
                )
            }
            for check in checks {
                print("\(check.0): \(check.1 ? "PASS" : "FAIL")")
            }
            let passed = checks.filter(\.1).count
            print("result: \(passed)/\(checks.count)")
            exit(passed == checks.count ? 0 : 1)
        } catch {
            print("self-test error: \(error)")
            exit(1)
        }
    }

    private func renderSnapshot(to path: String) {
        let dark = argument(after: "--appearance")?.lowercased() != "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let colorScheme: ColorScheme = dark ? .dark : .light
        let size = snapshotSize()

        let hosting = NSHostingView(rootView: AnyView(
            ContentView()
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
        for _ in 0..<12 {
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.015))
        }

        let bounds = NSRect(origin: .zero, size: size)
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
            exit(1)
        }
        rep.size = size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("snapshot: \(path) · \(Int(size.width))x\(Int(size.height))")
        } catch {
            print("snapshot write failed: \(error)")
            exit(1)
        }
    }

    private func snapshotSize() -> NSSize {
        guard let raw = argument(after: "--size") else {
            return NSSize(width: 1_160, height: 780)
        }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return NSSize(width: 1_160, height: 780)
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
