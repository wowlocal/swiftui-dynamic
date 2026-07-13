import AppKit
import AppKitPixelRelay
import SwiftUI

@main
struct AppKitPixelRelayNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Pixel Relay — Native") {
            ContentView()
                .frame(minWidth: 980, minHeight: 680)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in
                await runSelfTest()
            }
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

    private func runSelfTest() async {
        let endpoint = argument(after: "--url")
            ?? "http://127.0.0.1:8765/pixel-relay-source.png"
        do {
            let download = try await RelayNetworkPipeline.fetch(
                endpoint: endpoint,
                effect: .warm,
                intensity: 0.82
            )
            let output = download.pipeline
            let effectOutputs = try RelayEffect.allCases.map { effect in
                try AppKitImagePipeline.process(
                    data: download.sourceData,
                    effect: effect,
                    intensity: 1
                )
            }
            let zeroIntensity = try AppKitImagePipeline.process(
                data: download.sourceData,
                effect: .warm,
                intensity: 0
            )
            let original = effectOutputs[RelayEffect.original.rawValue]
            let exportURL = URL(fileURLWithPath: "/tmp/appkit-pixel-relay-selftest.png")
            try output.pngData.write(to: exportURL)
            let exported = try Data(contentsOf: exportURL)
            let imageSizeWorked = Int(output.image.size.width) == output.width
                && Int(output.image.size.height) == output.height
            let checks = [
                ("URLSession HTTP status", download.statusCode == 200),
                ("network payload", download.sourceBytes > 100),
                ("NSBitmapImageRep decode", output.width == 96 && output.height == 64),
                ("four distinct image effects", Set(effectOutputs.map(\.checksum)).count == 4),
                ("zero-intensity identity", zeroIntensity.checksum == original.checksum),
                ("luminance histogram", output.histogram.count == 12
                    && output.histogram.allSatisfy { 0...1 ~= $0 }),
                ("AppKit PNG encoding", output.pngData.count > 100),
                ("NSImage construction", imageSizeWorked),
                ("export round-trip", exported == output.pngData),
            ]
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
        for _ in 0..<8 {
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
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
        } catch {
            print("snapshot write failed: \(error)")
            exit(1)
        }
    }

    private func snapshotSize() -> NSSize {
        guard let raw = argument(after: "--size") else {
            return NSSize(width: 1100, height: 760)
        }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]) else {
            return NSSize(width: 1100, height: 760)
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
