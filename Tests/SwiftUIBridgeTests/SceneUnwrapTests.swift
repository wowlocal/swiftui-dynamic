import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
import SwiftUIBridge

/// The icecubes shape: the App's scene content is NOT a literal view
/// constructor but a computed property or method call — the probe must
/// unwrap it to the actual View, never surface `(function view)`.
@Suite struct SceneUnwrapTests {
    private func sceneRootStrings(_ source: String) throws -> String {
        let registry = TraceRegistry()
        let interpreter = Interpreter(registry: registry)
        _ = try interpreter.run(source: source)
        guard let (app, sceneBody) = interpreter.declaredAppSceneRoot() else {
            return "NO-SCENE"
        }
        let views = try interpreter.sceneViews(app: app, sceneBody: sceneBody)
        return views.map { $0.stringified }.joined(separator: "|")
    }

    @Test func computedPropertySceneContent() throws {
        let rendered = try sceneRootStrings("""
        struct HomeView: View {
            var body: some View { Text("home sweet home") }
        }
        @main struct DemoApp: App {
            var rootView: some View { HomeView() }
            var body: some Scene {
                WindowGroup { rootView }
            }
        }
        """)
        #expect(!rendered.contains("function"), "scene content stayed a function value: \(rendered)")
    }

    @Test func methodCallSceneContent() throws {
        let rendered = try sceneRootStrings("""
        struct HomeView: View {
            var body: some View { Text("home sweet home") }
        }
        @main struct DemoApp: App {
            func makeRoot() -> some View { HomeView() }
            var body: some Scene {
                WindowGroup { makeRoot() }
            }
        }
        """)
        #expect(!rendered.contains("function"), "scene content stayed a function value: \(rendered)")
    }

    @Test func extensionScenePropertyResolves() throws {
        let rendered = try LiveCheckSupport.renderedStrings(source: """
        struct HomeView: View {
            var body: some View { Text("home sweet home") }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                appScene
                otherScenes
            }
        }
        extension DemoApp {
            var appScene: some Scene {
                WindowGroup { HomeView() }
            }
            var otherScenes: some Scene {
                WindowGroup(id: "aux") { Text("aux") }
            }
        }
        """)
        #expect(rendered.joined(separator: "|").contains("home sweet home"),
                "scene property didn't resolve: \(rendered) (root \(LiveCheckSupport.lastRootSymbol))")
        #expect(LiveCheckSupport.lastRootSymbol.hasPrefix("scene:"),
                "root should come from the scene rung, got \(LiveCheckSupport.lastRootSymbol)")
    }

    /// IceCubes' scene/list/row composition exceeds the old traversal depth
    /// even though the branch is finite. `AnyView` makes this recursive shape
    /// valid native SwiftUI; the terminal text must remain observable.
    @Test func finiteViewBranchCanExceedFortyEightLevels() throws {
        let rendered = try LiveCheckSupport.renderedStrings(source: """
        struct FiniteNest: View {
            let remaining: Int

            var body: some View {
                if remaining == 0 {
                    AnyView(Text("deep marker"))
                } else {
                    AnyView(FiniteNest(remaining: remaining - 1))
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                FiniteNest(remaining: 56)
            }
        }
        """)

        #expect(rendered.contains("deep marker"))
    }

    @Test func interpreterHostUsesAppOwnedRootArguments() throws {
        let source = """
        final class Model: ObservableObject {
            @Published var title: String
            init(title: String) { self.title = title }
        }
        struct ContentView: View {
            @ObservedObject var model: Model
            var body: some View {
                if model.title != "app-owned" { fatalError("synthesized model") }
                Text(model.title)
            }
        }
        @main struct DemoApp: App {
            @StateObject var model = Model(title: "app-owned")
            var body: some Scene {
                WindowGroup { ContentView(model: model) }
            }
        }
        """

        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: source, lazyTopLevelGlobals: true) {
        case .failure(let error):
            Issue.record("render failed: \(error)")
        case .success(let view):
            let hosting = NSHostingView(rootView: view.frame(width: 300, height: 200))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(RenderDiagnostics.errors.isEmpty)
        }
    }
}
