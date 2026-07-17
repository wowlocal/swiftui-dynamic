import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck FlowLayout class: `alignment.horizontal.percent` — the app
/// extension switches on HorizontalAlignment. Before the alignment family
/// joined the host seam, `.center` stayed a marker chain, the multiply
/// absorbed to 0, and every pill row placed LEADING instead of centered.
@Suite struct AlignmentSwitchProbeTests {
    @MainActor
    @Test func alignmentPercentMatchesNativeSwitch() throws {
        let source = """
        extension HorizontalAlignment {
            var percent: Double {
                switch self {
                case .leading: return 0
                case .trailing: return 1
                default: return 0.5
                }
            }
        }
        let center: Alignment = .center
        let leading: Alignment = .leading
        let trailing: Alignment = .trailing
        let centerOut = center.horizontal.percent
        let leadingOut = leading.horizontal.percent
        let trailingOut = trailing.horizontal.percent
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("centerOut")?.doubleValue == 0.5)
        #expect(interpreter.globals.lookup("leadingOut")?.doubleValue == 0)
        #expect(interpreter.globals.lookup("trailingOut")?.doubleValue == 1)
    }
}
