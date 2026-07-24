import AppKit
import SwiftInterpreter
import SwiftUI
import SwiftUIBridge

@main
struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Interpreter build configurations SNAPSHOT the platform at
        // interpreter init — the flags must be applied before ANY scene
        // construction can create one (didFinishLaunching is too late for
        // instances created during scene setup; the frozen iOS default
        // made #if os(iOS) blocks active in the live window only).
        DemoApp.applyPlatformFlag()
        DemoApp.applyNetworkFlag()
    }

    /// `swift run DynamicSwiftUIDemo --project External/oss/IceCubesApp`
    /// renders a whole checked-out project live instead of the editor demo.
    static var projectDirectory: String? {
        CommandLine.arguments.firstIndex(of: "--project").flatMap { index in
            CommandLine.arguments.indices.contains(index + 1)
                ? CommandLine.arguments[index + 1] : nil
        }
    }

    /// `--sweep <outDir>` (with --project): drive the LIVE window with real
    /// NSEvents after the project renders — the R4 "a person can use it"
    /// check. Captures land in outDir; the process exits with the verdict.
    static var sweepDirectory: String? {
        CommandLine.arguments.firstIndex(of: "--sweep").flatMap { index in
            CommandLine.arguments.indices.contains(index + 1)
                ? CommandLine.arguments[index + 1] : nil
        }
    }

    /// `--network live` → real HTTP (the human demo gate);
    /// `--network replay:<fixturesDir>` → recorded responses.
    /// With no flag, the interactive editor demo uses live HTTP so city
    /// search works. Deterministic/offline runs opt into replay explicitly.
    /// Whole-project previews remain absorbed unless explicitly enabled.
    static func applyNetworkFlag() {
        guard let index = CommandLine.arguments.firstIndex(of: "--network"),
              CommandLine.arguments.indices.contains(index + 1) else {
            if projectDirectory == nil {
                NetworkBridge.policy = .live
            }
            return
        }
        let mode = CommandLine.arguments[index + 1]
        if mode == "live" {
            NetworkBridge.policy = .live
        } else if mode.hasPrefix("replay:") {
            NetworkBridge.policy = .replay(fixturesDirectory: String(mode.dropFirst("replay:".count)))
        }
    }

    /// Override the interpreted `#if os(...)` / `#if canImport(...)` identity.
    /// The corpus-oriented default is iOS; native macOS project checks can use
    /// `--platform macOS`.
    static func applyPlatformFlag() {
        guard let index = CommandLine.arguments.firstIndex(of: "--platform"),
              CommandLine.arguments.indices.contains(index + 1) else {
            return
        }
        Interpreter.interpretsAsPlatform = CommandLine.arguments[index + 1]
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
            rendered = InterpreterHost().render(
                source: source,
                projectResourceRoot: directory,
                lazyTopLevelGlobals: true)
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
        DemoApp.applyPlatformFlag()
        DemoApp.applyNetworkFlag()
        if let index = CommandLine.arguments.firstIndex(of: "--render-png"),
           CommandLine.arguments.indices.contains(index + 1) {
            renderSnapshot(to: CommandLine.arguments[index + 1])
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        if let sweepDirectory = DemoApp.sweepDirectory {
            Task { await SweepDriver.run(outDirectory: sweepDirectory) }
        }
        // Self-capture evidence for headless verification sessions that
        // lack screen-recording access: after the LIVE interactive window
        // settles, write its contentView bitmap and keep running.
        if let capturePath = ProcessInfo.processInfo
            .environment["DYNAMIC_DEMO_SELF_CAPTURE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                guard let window = NSApp.windows.first,
                      let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    return
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: capturePath))
            }
        }
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
        let rendered = if let directory = DemoApp.projectDirectory {
            InterpreterHost().render(
                source: source,
                projectResourceRoot: directory,
                lazyTopLevelGlobals: lazyGlobals)
        } else {
            InterpreterHost().render(
                source: source,
                lazyTopLevelGlobals: lazyGlobals)
        }
        switch rendered {
        case .success(let view):
            let darkSnapshot = CommandLine.arguments.firstIndex(of: "--appearance").flatMap { index in
                CommandLine.arguments.indices.contains(index + 1)
                    ? CommandLine.arguments[index + 1].lowercased() : nil
            } == "dark"
            let appearance = NSAppearance(named: darkSnapshot ? .darkAqua : .aqua)
            let colorScheme: ColorScheme = darkSnapshot ? .dark : .light
            // NSHostingView in a never-shown window (not ImageRenderer):
            // AppKit-backed controls don't draw under ImageRenderer, and
            // SwiftUI layers don't draw via cacheDisplay without a window.
            let hosting = NSHostingView(rootView: view
                .environment(\.colorScheme, colorScheme)
                .padding(40)
                .background(Color(nsColor: .windowBackgroundColor)))
            hosting.appearance = appearance
            hosting.layoutSubtreeIfNeeded()
            // Samples are components — size to fit. Projects are full-screen
            // apps (scroll/GeometryReader roots collapse fittingSize to
            // nothing); give them an iPhone-ish canvas instead.
            var size = DemoApp.projectDirectory == nil
                ? hosting.fittingSize
                : NSSize(width: 470, height: 780)
            // --size WxH: match a native twin's fixed canvas (FoodTruck R2
            // captures compare at identical point size + 1x scale).
            if let index = CommandLine.arguments.firstIndex(of: "--size"),
               CommandLine.arguments.indices.contains(index + 1) {
                let parts = CommandLine.arguments[index + 1].split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    size = NSSize(width: w, height: h)
                }
            }
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = hosting
            window.orderFrontRegardless()
            // Nested interpreted views publish additional SwiftUI updates as
            // each body is discovered. Drain a handful of frames so a deep
            // project snapshot reaches the same fixed point as the live app.
            for _ in 0..<8 {
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            // A shown Retina window makes bitmapImageRepForCachingDisplay
            // allocate backing pixels at 2x while cacheDisplay still paints
            // this offscreen host in point coordinates, leaving three black
            // quadrants. Use an explicit 1x bitmap for deterministic CLI
            // snapshots on every display scale.
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(hosting.bounds.width.rounded(.up))),
                pixelsHigh: max(1, Int(hosting.bounds.height.rounded(.up))),
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
            rep.size = hosting.bounds.size
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
