import AppKit
import SwiftInterpreter
import SwiftUI
import SwiftUIBridge

@main
struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// `swift run DynamicSwiftUIDemo --project External/oss/IceCubesApp`
    /// renders a whole checked-out project live instead of the editor demo.
    static var projectDirectory: String? {
        CommandLine.arguments.firstIndex(of: "--project").flatMap { index in
            CommandLine.arguments.indices.contains(index + 1)
                ? CommandLine.arguments[index + 1] : nil
        }
    }

    var body: some Scene {
        WindowGroup("Dynamic SwiftUI") {
            if let directory = Self.projectDirectory {
                ProjectPreviewView(directory: directory)
                    .frame(minWidth: 420, minHeight: 800)
            } else {
                ContentView()
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
    }
}

/// Merge a project directory the way ProjectCheck does (imports stripped,
/// Tests excluded), interpret it, and host the root view live.
struct ProjectPreviewView: View {
    let directory: String
    @State private var rendered: Result<AnyView, RuntimeError>?

    var body: some View {
        VStack(spacing: 0) {
            switch rendered {
            case .success(let view):
                view
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error):
                Label(error.description, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding()
                Spacer()
            case nil:
                ProgressView("Interpreting \(URL(fileURLWithPath: directory).lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(URL(fileURLWithPath: directory).lastPathComponent)
                Spacer()
                Text("\(RenderDiagnostics.errors.count) render diagnostics")
                    .foregroundStyle(RenderDiagnostics.errors.isEmpty ? Color.secondary : Color.orange)
            }
            .font(.caption)
            .padding(6)
        }
        .task {
            let source = mergedProjectSource(at: directory)
            rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        }
    }
}

/// The same merge rules ProjectCheck uses.
func mergedProjectSource(at root: String) -> String {
    ProjectMaterial.mergedSource(at: root)
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
        let source: String
        let lazyGlobals: Bool
        if let directory = DemoApp.projectDirectory {
            source = mergedProjectSource(at: directory)
            lazyGlobals = true
        } else {
            source = sample.source
            lazyGlobals = false
        }
        switch InterpreterHost().render(source: source, lazyTopLevelGlobals: lazyGlobals) {
        case .success(let view):
            // NSHostingView in a never-shown window (not ImageRenderer):
            // AppKit-backed controls don't draw under ImageRenderer, and
            // SwiftUI layers don't draw via cacheDisplay without a window.
            let hosting = NSHostingView(rootView: view.padding(40).background(Color.white))
            hosting.layoutSubtreeIfNeeded()
            // Samples are components — size to fit. Projects are full-screen
            // apps (scroll/GeometryReader roots collapse fittingSize to
            // nothing); give them an iPhone-ish canvas instead.
            let size = DemoApp.projectDirectory == nil
                ? hosting.fittingSize
                : NSSize(width: 470, height: 780)
            hosting.frame = NSRect(origin: .zero, size: size)
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
            // Body-evaluation errors render inline and don't fail the
            // snapshot; surface them so scripts can tell clean from broken.
            for (view, error) in RenderDiagnostics.errors {
                FileHandle.standardError.write(Data("diagnostic [\(view)]: \(error)\n".utf8))
            }
        case .failure(let error):
            FileHandle.standardError.write(Data("render error: \(error)\n".utf8))
            exit(1)
        }
    }
}
