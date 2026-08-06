import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// IceCubes' `TimelineToolbarTitleView` class: a `ToolbarContent` conformer —
/// NOT a View — that reads `@Environment(MastodonClient.self)` and draws
/// `Text(client.server)` under the timeline's headline. A View's `@Environment`
/// properties are filled by the host that renders it (`InterpretedView`); a
/// non-View result-builder conformer has no such host, so its properties stayed
/// unset and every value read off them rendered EMPTY. On the trending-timeline
/// screen that erased the toolbar title's second line, and the surviving first
/// line then centered as a one-child VStack instead of a two-child one.
///
/// The conformer keeps the real view's shape: both `Text`s sit in one `switch`
/// case in ViewBuilder position (TimelineToolbarTitleView.swift:26-31), which
/// was the competing hypothesis for the missing line. Recording each line
/// separately tells the two apart, and pins multi-view switch-case collection —
/// which had no suite coverage at all — at the same time.
///
/// The macOS `NSHostingView` harness does not draw toolbars at all (a present
/// vs absent toolbar line is pixel-identical here), so this is pinned on the
/// value the conformer's body actually observes rather than on pixels — a
/// bitmap comparison of a toolbar would pass no matter what the bug did.
@Suite(.serialized)
struct ResultBuilderConformerEnvironmentTests {
    @MainActor
    @Test func toolbarContentConformerSeesItsEnclosingEnvironment() throws {
        let source = """
        @Observable final class MastodonClient {
            public let server: String
            init(server: String) { self.server = server }
        }
        var observedServer = "<never-read>"
        var observedHeadline = "<never-read>"
        func record(_ value: String) -> String {
            observedServer = value
            return value
        }
        func recordHeadline(_ value: String) -> String {
            observedHeadline = value
            return value
        }
        enum Filter { case link, trending }
        struct TitleBar: ToolbarContent {
            @Environment(MastodonClient.self) private var client
            var timeline: Filter
            var body: some ToolbarContent {
                ToolbarItem(placement: .principal) {
                    VStack(alignment: .center) {
                        switch timeline {
                        case .link:
                            Text("Link")
                                .font(.headline)
                            Text("link.example")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        default:
                            Text(recordHeadline("Trending"))
                                .font(.headline)
                            Text(record(client.server))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        struct Screen: View {
            var body: some View {
                NavigationStack {
                    Color.white
                        .toolbar {
                            TitleBar(timeline: .trending)
                        }
                }
            }
        }
        struct ContentView: View {
            var body: some View {
                Screen()
                    .environment(MastodonClient(server: "mastodon.social"))
            }
        }
        ContentView()
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(source: source)
        guard case .success(let view) = rendered else {
            Issue.record("toolbar-environment render failed: \(rendered)")
            return
        }
        // Rasterize: the conformer's body only runs when the view is hosted.
        Self.rasterize(view)

        let interpreter = try #require(InterpreterHost.lastInterpreter)
        let observed = interpreter.globals.lookup("observedServer")?.stringValue
        let headline = interpreter.globals.lookup("observedHeadline")?.stringValue
        // Both views of the matched `switch` case must run. Recording them
        // separately keeps the two candidate mechanisms distinguishable: a
        // headline WITHOUT a server would mean the builder dropped the case's
        // second view, while neither would mean the case body never ran.
        #expect(headline == "Trending")
        #expect(observed == "mastodon.social")
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    /// The same conformer with NOTHING injected still reads as absent rather
    /// than as a freshly synthesized stand-in — a missing injection must not
    /// invent a model whose `init` runs (the fresh-store doctrine).
    @MainActor
    @Test func uninjectedConformerDoesNotSynthesizeAModel() throws {
        let source = """
        @Observable final class MastodonClient {
            public let server: String
            init(server: String) { self.server = server }
        }
        var observedServer = "<never-read>"
        func record(_ value: String) -> String {
            observedServer = value
            return value
        }
        struct TitleBar: ToolbarContent {
            @Environment(MastodonClient.self) private var client
            var body: some ToolbarContent {
                ToolbarItem(placement: .principal) {
                    Text(record(client.server))
                }
            }
        }
        struct ContentView: View {
            var body: some View {
                NavigationStack {
                    Color.white
                        .toolbar {
                            TitleBar()
                        }
                }
            }
        }
        ContentView()
        """

        RenderDiagnostics.reset()
        defer { RenderDiagnostics.reset() }
        let rendered = InterpreterHost().render(source: source)
        guard case .success(let view) = rendered else {
            Issue.record("uninjected render failed: \(rendered)")
            return
        }
        Self.rasterize(view)

        let interpreter = try #require(InterpreterHost.lastInterpreter)
        let observed = interpreter.globals.lookup("observedServer")?.stringValue
        #expect(observed != "mastodon.social")
    }

    private static func rasterize(_ view: AnyView) {
        let size = NSSize(width: 400, height: 160)
        let hosting = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
}
