import AppKit
import SwiftUI
import SwiftUIBridge

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
        if let index = CommandLine.arguments.firstIndex(of: "--render-png"),
           CommandLine.arguments.indices.contains(index + 1) {
            renderSnapshot(to: CommandLine.arguments[index + 1])
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Headless verification hook: render the counter sample through the real
    /// interpreter pipeline to a PNG (no window, no screen-recording permission).
    private func renderSnapshot(to path: String) {
        let sampleName = CommandLine.arguments.firstIndex(of: "--sample").flatMap { index in
            CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
        }
        let sample = SamplePrograms.all.first { $0.name == sampleName } ?? SamplePrograms.counter
        switch InterpreterHost().render(source: sample.source) {
        case .success(let view):
            // NSHostingView in a never-shown window (not ImageRenderer):
            // AppKit-backed controls don't draw under ImageRenderer, and
            // SwiftUI layers don't draw via cacheDisplay without a window.
            let hosting = NSHostingView(rootView: view.padding(40).background(Color.white))
            hosting.layoutSubtreeIfNeeded()
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                FileHandle.standardError.write(Data("snapshot failed\n".utf8))
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
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
        case .failure(let error):
            FileHandle.standardError.write(Data("render error: \(error)\n".utf8))
            exit(1)
        }
    }
}
