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
}
