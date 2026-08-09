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

    /// A framework value returned by a computed property on an interpreted
    /// value must retain its concrete host payload when it becomes the next
    /// generated call's argument. This is the ordinary palette-model shape,
    /// independent of any particular modifier or application.
    @Test func computedSourceColorFeedsGeneratedModifier() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)
        let result = try interpreter.run(source: """
        import SwiftUI
        struct PaletteEntry {
            let hue: Double
            var color: Color {
                Color(hue: hue, saturation: 0.5, brightness: 0.8)
            }
        }
        struct Palette {
            let foreground: PaletteEntry
        }
        enum Phase {
            case day
            init(daylight: Bool) {
                self.init(index: daylight ? 0 : 1)
            }
            init(index: Int) {
                self = .day
            }
            static let dayPalette = Palette(
                foreground: PaletteEntry(hue: 0.3))
            var palette: Palette {
                switch self {
                case .day: Self.dayPalette
                }
            }
        }
        Text("palette")
            .colorMultiply(Phase(daylight: true).palette.foreground.color)
        """)
        #expect(registry.isViewValue(result))
    }

    @Test func platformSystemColors() throws {
        #expect(try evalColor("Color(uiColor: .systemGroupedBackground)") != nil)
        #expect(try evalColor("Color(nsColor: .windowBackgroundColor)") != nil)
    }

    /// Target-specific SwiftUI overlays expose platform-color initializers in
    /// addition to the host overlay BridgeGen compiles against. Their explicit
    /// platform values must still cross the generated adapter as real Colors.
    @Test func explicitPlatformColorValues() throws {
        #expect(try evalColor("Color(UIColor.secondaryLabel)") != nil)
        #expect(try evalColor("Color(uiColor: UIColor.secondaryLabel)") != nil)
    }

    /// IceCubes' status action buttons pass the explicit UIKit value straight
    /// into a view modifier. Pin the argument-position boundary as well as the
    /// standalone constructor result: the concrete Color must survive until
    /// the modifier's generated coercion runs.
    @Test func explicitPlatformColorFeedsViewModifier() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let foreignGraphics = ProjectMaterial.mergedSource(
            source: """
            import UIKit
            typealias Color = UIColor
            """,
            moduleName: "ForeignGraphics")
        let consumer = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI
            struct StatusActionProbe: View {
                var body: some View {
                    Text("probe")
                        .foregroundColor(Color(UIColor.secondaryLabel))
                }
            }
            StatusActionProbe().body
            """,
            moduleName: "StatusKit")
        _ = try interpreter.run(source: foreignGraphics + consumer)
    }

    @Test func sameModuleAndExportedAliasesRemainVisible() throws {
        let local = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI
            typealias Palette = Color
            Palette(red: 0.2, green: 0.4, blue: 0.6)
            """,
            moduleName: "PaletteKit")
        let localValue = try Interpreter(registry: ViewRegistry()).run(
            source: local)
        #expect(Coerce.colorLike(localValue) != nil)

        let exported = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI
            public typealias Palette = Color
            """,
            moduleName: "PaletteKit")
        let consumer = ProjectMaterial.mergedSource(
            source: """
            import PaletteKit
            Palette(red: 0.2, green: 0.4, blue: 0.6)
            """,
            moduleName: "Consumer")
        let importedValue = try Interpreter(registry: ViewRegistry()).run(
            source: exported + consumer)
        #expect(Coerce.colorLike(importedValue) != nil)
    }

    @Test func foreignAliasDoesNotRetypeStoredProperty() throws {
        let foreignGraphics = ProjectMaterial.mergedSource(
            source: """
            import UIKit
            typealias Color = UIColor
            """,
            moduleName: "ForeignGraphics")
        let consumer = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI
            struct ThemeProbe {
                var labelColor: Color = .black
            }
            ThemeProbe().labelColor
            """,
            moduleName: "DesignSystem")
        let value = try Interpreter(registry: ViewRegistry()).run(
            source: foreignGraphics + consumer)
        #expect(Coerce.colorLike(value) != nil)
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

/// Edge.Set spelled as an array literal — `.edgesIgnoringSafeArea([.top,
/// .bottom])` (damus) and the empty `[]` no-op form.
@Suite struct EdgeSetCoercionTests {
    @Test func arrayLiteralUnions() throws {
        let set = try Coerce.edgeSet(.native([
            RuntimeValue.implicitMember("top"), RuntimeValue.implicitMember("bottom"),
        ]))
        #expect(set.contains(.top))
        #expect(set.contains(.bottom))
        #expect(!set.contains(.leading))
    }

    @Test func emptyArrayIsNoEdges() throws {
        let set = try Coerce.edgeSet(.native([RuntimeValue]()))
        #expect(set.isEmpty)
    }

    @Test func singleMemberStillWorks() throws {
        #expect(try Coerce.edgeSet(.implicitMember("horizontal")) == .horizontal)
    }
}
