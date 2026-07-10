import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The SwiftUIFlux genre: views conform to View THROUGH a protocol
/// (`ConnectedView: View`) and get `body` from that protocol's EXTENSION —
/// both must count for the render pipeline.
@Suite struct ProtocolViewConformanceTests {
    @Test func protocolExtensionBodyRendersForTransitiveConformers() throws {
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
        let strings = try LiveCheckSupport.renderedStrings(source: source)
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
}
