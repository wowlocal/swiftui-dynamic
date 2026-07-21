import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Classes closed on the achnbrowser rung (queue 3c), pinned smallest-first.
@Suite struct ACHNLadderTests {
    @Test func nilItemSheetContentNeverRuns() async throws {
        // `.sheet(item:)` over a nil route: native never evaluates the
        // content closure — `$0.makeSheetView()` must not absorb the root.
        let source = """
        enum Route: Identifiable {
            case detail
            var id: Int { 0 }
        }
        struct Home: View {
            @State private var route: Route? = nil
            var body: some View {
                Text("home alive")
                    .sheet(item: $route, content: { $0.makeSheetView() })
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { Home() }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.contains("home alive") }, "\(strings)")
    }

    @Test func itemSheetContentReceivesTheUnwrappedItem() async throws {
        let source = """
        struct Route: Identifiable {
            let id: Int
            let title: String
        }
        struct Home: View {
            @State private var route: Route? = Route(id: 1, title: "details")
            var body: some View {
                Text("home")
                    .sheet(item: $route) { item in
                        Text(item.title)
                    }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("details"), "\(strings)")
    }

    @Test func dateConstructorsAreReal() throws {
        let source = """
        let epoch = Date(timeIntervalSince1970: 100)
        let later = Date(timeInterval: 50, since: epoch)
        "\\(Int(later.timeIntervalSince1970))"
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "150")
    }

    @Test func classicEnvironmentKeyDefaultResolves() async throws {
        // The 2020 pattern: EnvironmentKey.defaultValue behind a computed
        // EnvironmentValues extension — unset reads get the declared default.
        let source = """
        struct GreetingKey: EnvironmentKey {
            static let defaultValue = "hello-default"
        }
        extension EnvironmentValues {
            var greeting: String {
                get { self[GreetingKey.self] }
                set { self[GreetingKey.self] = newValue }
            }
        }
        struct Home: View {
            @Environment(\\.greeting) private var greeting
            var body: some View {
                Text("greeting: " + greeting)
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { Home() }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.contains("greeting: hello-default") }, "\(strings)")
    }

    @Test func nilInBuilderRendersNothing() async throws {
        let source = """
        struct Home: View {
            @State var pick = [Int]().randomElement()
            var body: some View {
                VStack {
                    Text("before")
                    pick.map { Text("pick \\\\($0)") }
                    Text("after")
                }
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { Home() }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.contains("before") } && strings.contains { $0.contains("after") },
                "\(strings)")
    }
}
