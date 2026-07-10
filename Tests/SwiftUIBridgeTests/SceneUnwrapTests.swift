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
}
