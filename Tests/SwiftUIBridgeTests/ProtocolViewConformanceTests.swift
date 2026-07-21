import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The SwiftUIFlux genre: views conform to View THROUGH a protocol
/// (`ConnectedView: View`) and get `body` from that protocol's EXTENSION —
/// both must count for the render pipeline.
@Suite struct ProtocolViewConformanceTests {
    @Test func protocolExtensionBodyRendersForTransitiveConformers() async throws {
        let source = """
        protocol Card: View {
            func title() -> String
        }
        extension Card {
            var body: some View {
                Text("card: " + title())
            }
        }
        struct WeatherCard: Card {
            func title() -> String { "sunny" }
        }
        struct Screen: View {
            var body: some View {
                WeatherCard()
            }
        }
        @main struct DemoApp: App {
            var body: some Scene {
                WindowGroup { Screen() }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.contains("card: sunny") },
                "protocol-extension body did not render: \(strings)")
    }

    @Test func transitiveConformanceMarksSymbolAsView() throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        _ = try interpreter.run(source: """
        protocol Inner: View {}
        protocol Outer: Inner {}
        struct Deep: Outer {
            var body: some View { Text("x") }
        }
        struct Direct: View {
            var body: some View { Text("y") }
        }
        Deep()
        """, lazyTopLevelGlobals: true)
        let deep = interpreter.structSymbols.first { $0.name == "Deep" }
        #expect(deep?.conformsToView == true, "two-hop protocol chain must reach View")
    }

    /// View libraries commonly vend a namespace that captures `Self`, then
    /// expose modifiers from a conditional extension on the captured generic
    /// content. The wrapper must recognize an interpreted View conformance;
    /// otherwise compiled-project fallback absorbs the chain and drops the
    /// original view from the render tree.
    @Test func constrainedGenericViewNamespacePreservesContent() async throws {
        let unrelated = ProjectMaterial.mergedSource(source: """
        public struct View {}
        """, moduleName: "DatabaseKit")
        let dependency = ProjectMaterial.mergedSource(source: """
        import SwiftUI

        public struct EmojiNamespace<Content> {
            let content: Content
            public init(_ content: Content) { self.content = content }
        }

        public extension View {
            var emojiText: EmojiNamespace<Self> {
                EmojiNamespace(self)
            }
        }

        public extension EmojiNamespace where Content: View {
            func size(_ value: Double?) -> some View {
                content.opacity(value ?? 1)
            }

            func baselineOffset(_ value: Double?) -> some View {
                content.opacity(1)
            }
        }
        """, moduleName: "NamespaceKit")

        let probe = ProjectMaterial.mergedSource(source: """
        import SwiftUI
        import NamespaceKit

        struct NestedLabel: View {
            var body: some View { Text("namespace-content") }
        }

        struct ContentView: View {
            var body: some View {
                NestedLabel()
                    .opacity(1)
                    .emojiText.size(1)
                    .emojiText.baselineOffset(2)
            }
        }
        """, moduleName: "Probe")

        let strings = try await LiveCheckSupport.renderedStrings(
            source: unrelated + dependency + probe)
        #expect(strings.contains("namespace-content"),
                "conditional namespace dropped its wrapped View: \(strings)")
    }
}
