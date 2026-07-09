import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Component colors — `Color(red:green:blue:opacity:)` and friends — are the
/// single most common custom-palette idiom in the corpus (2048's whole tile
/// palette). They must produce REAL SwiftUI Colors, not absorbing stubs.
@Suite struct ColorConstructorTests {
    private func evalColor(_ source: String) throws -> Color? {
        let interpreter = Interpreter(registry: ViewRegistry())
        let value = try interpreter.run(source: source)
        return Coerce.colorLike(value)
    }

    @Test func rgbaComponents() throws {
        let color = try evalColor("Color(red: 0.9, green: 0.2, blue: 0.1, opacity: 0.5)")
        #expect(color != nil)
        let resolved = try #require(color).resolve(in: EnvironmentValues())
        #expect(abs(Double(resolved.red) - 0.9) < 0.01)
        #expect(abs(Double(resolved.opacity) - 0.5) < 0.01)
    }

    @Test func rgbComponentsWithoutOpacity() throws {
        let color = try evalColor("Color(red: 0.2, green: 0.5, blue: 0.9)")
        #expect(color != nil)
        let resolved = try #require(color).resolve(in: EnvironmentValues())
        #expect(abs(Double(resolved.blue) - 0.9) < 0.01)
    }

    @Test func whiteComponent() throws {
        let color = try evalColor("Color(white: 0.65)")
        #expect(color != nil)
    }

    @Test func hueSaturationBrightness() throws {
        let color = try evalColor("Color(hue: 0.3, saturation: 0.5, brightness: 0.8)")
        #expect(color != nil)
    }

    @Test func rgbaFlowsIntoFill() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                Rectangle()
                    .fill(Color(red: 0.96, green: 0.94, blue: 0.90, opacity: 1.00))
                    .frame(width: 20, height: 20)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 1)
    }
}
