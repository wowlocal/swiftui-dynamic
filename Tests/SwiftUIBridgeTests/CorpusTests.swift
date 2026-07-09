import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Corpus files live next to this test file (excluded from compilation in the
/// manifest) and are listed via #filePath. Test arguments are enumerated off
/// the main actor, so this path must be nonisolated despite the package-wide
/// MainActor default — hence the free function instead of a closure initializer.
private nonisolated func listCorpusFiles() -> [String] {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Corpus")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") }.sorted()
}

nonisolated let corpusFiles: [String] = listCorpusFiles()

/// The "runs real-world code" gate: every program in Corpus/ must interpret,
/// deep-render (every View body force-evaluated, not just the lazy root),
/// survive having all its actions invoked, and render through real SwiftUI
/// hosting without inline errors.
enum Corpus {
    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite struct CorpusTests {
    @Test func corpusIsPopulated() {
        #expect(corpusFiles.count >= 10)
    }

    @Test(arguments: corpusFiles)
    func traceDeepRenderWithInteractions(file: String) throws {
        let report = try HeadlessVerifier.verify(source: try Corpus.source(file))
        #expect(report.nodeCount > 1, "\(file) rendered a trivial tree")
    }

    /// KeyframeAnimator/PhaseAnimator content receives the animated value —
    /// headlessly the initialValue (or first phase) seeds it.
    @Test func keyframeAnimatorContentReceivesInitialValue() throws {
        let source = """
        struct Frame {
            var top: CGFloat = 0
            var opacity: CGFloat = 1
        }

        struct ContentView: View {
            var body: some View {
                KeyframeAnimator(initialValue: Frame(), trigger: true) { value in
                    Text("t")
                        .offset(y: value.top)
                        .opacity(value.opacity)
                } keyframes: { _ in
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// `NSScreen.main?.visibleFrame` — real screen when present, a
    /// laptop-shaped rect headlessly; members read as numbers.
    @Test func screenVisibleFrameServesRectMembers() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let frame = NSScreen.main?.visibleFrame ?? .zero
                let size = NSScreen.main?.visibleFrame.size
                Text("w=\\(frame.width) h=\\(size?.height ?? 0)")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// `DispatchQueue.main.asyncAfter(deadline: .now() + delay)` schedules
    /// the interpreted closure without error (click-through fires it).
    @Test func asyncAfterSchedulesInertly() throws {
        let source = """
        struct ContentView: View {
            @State private var fired = false

            var body: some View {
                VStack {
                    Text(fired ? "fired" : "waiting")
                    Button("Later") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            fired = true
                        }
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 2)
    }

    /// Unknown-API trailing closures that don't yield views (the Lottie
    /// idiom: `LottieView { await LottieAnimation.loadedFrom(url:) }`) are
    /// recorded as configuration instead of failing the builder.
    @Test func nonBuilderClosureOnUnknownConstructorDegrades() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    LottieView {
                        await LottieAnimation.loadedFrom(url: "logo.json")
                    }
                    .playing(true)
                    Text("ready")
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 3)
    }

    /// Opaque host objects recorded as trace nodes behave like the mutable
    /// objects they stand for: property writes round-trip on reads
    /// (`gesture.name = id … gesture.name`).
    @Test func hostObjectPropertyWritesRoundTripInTrace() throws {
        let source = """
        struct ContentView: View {
            @State private var gesture: UIPanGestureRecognizer = {
                let gesture = UIPanGestureRecognizer()
                gesture.name = "pop-gesture"
                gesture.isEnabled = false
                return gesture
            }()

            var body: some View {
                Text(gesture.name ?? "unset")
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }

    /// Scene-management env actions are honest no-ops (no scene shell in our
    /// hosting) — declaring, rendering, and firing them must all work.
    @Test func windowActionsAreInertlyCallable() throws {
        let source = """
        struct ContentView: View {
            @Environment(\\.openWindow) private var openWindow
            @Environment(\\.dismissWindow) private var dismissWindow
            @State private var clicks = 0

            var body: some View {
                VStack {
                    Text("clicks: \\(clicks)")
                    Button("New window") {
                        openWindow(id: "second")
                        clicks += 1
                    }
                    Button("Close") {
                        dismissWindow()
                        clicks += 1
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount > 2)
    }

    /// MapKit views can't real-host (the bridge never imports MapKit), so the
    /// reader-family stub is verified trace-only: content deep-renders with a
    /// MapProxyStub whose conversions are honestly nil.
    @Test func mapReaderContentRendersWithProxyStub() throws {
        let source = """
        struct ContentView: View {
            @State private var status = "unresolved"

            var body: some View {
                MapReader { proxy in
                    VStack {
                        Text(status)
                        Button("Locate") {
                            if let point = proxy.convert(CGPoint(x: 10, y: 10), from: .global) {
                                status = "converted \\(point)"
                            } else {
                                status = "no map"
                            }
                        }
                    }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount > 2)
    }

    @Test(arguments: corpusFiles)
    func hostedRealRender(file: String) throws {
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: try Corpus.source(file)) {
        case .failure(let error):
            Issue.record("\(file): \(error)")
        case .success(let view):
            // Hosting in a (never-shown) window forces every nested
            // InterpretedView body to evaluate through the real gateways.
            let hosting = NSHostingView(rootView: view.frame(width: 480, height: 640))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(file) → \(viewName): \(error)")
            }
        }
    }

}
