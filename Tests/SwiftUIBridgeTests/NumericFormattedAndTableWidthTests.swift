import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck orders screen: the Donuts column was BLANK because numeric
/// `formatted()` only existed for Date — Foundation publishes it on the
/// numeric PROTOCOLS, which BridgeGen now expands to their concrete
/// runtime carriers (Int, Double). The Details column vanished because
/// `.width(60)` on the column DSL had no host member and the spec absorbed
/// into a chain marker.
@Suite struct NumericFormattedAndTableWidthTests {
    @MainActor
    @Test func numericFormattedMatchesNative() throws {
        let source = """
        let wholeNumber = 42.formatted()
        let sales = 34.68.formatted()
        let big = 1234567.formatted()
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        // Parity against the HOST's own native output — locale-proof.
        #expect(interpreter.globals.lookup("wholeNumber")?.stringValue == 42.formatted())
        #expect(interpreter.globals.lookup("sales")?.stringValue == 34.68.formatted())
        #expect(interpreter.globals.lookup("big")?.stringValue == 1_234_567.formatted())
    }

    @MainActor
    @Test func tableColumnWidthKeepsTheSpec() throws {
        let source = """
        let plain = TableColumn("Details") { EmptyView() }.width(60)
        let banded = TableColumn("Date") { EmptyView() }.width(min: 10, ideal: 20, max: 30)
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        guard case .host(let anyPlain)? = interpreter.globals.lookup("plain"),
              let fixed = anyPlain as? TableColumnSpec else {
            Issue.record(".width(60) did not return a TableColumnSpec")
            return
        }
        #expect(fixed.title == "Details")
        #expect(fixed.fixedWidth == 60)
        guard case .host(let anyBanded)? = interpreter.globals.lookup("banded"),
              let ranged = anyBanded as? TableColumnSpec else {
            Issue.record(".width(min:ideal:max:) did not return a TableColumnSpec")
            return
        }
        #expect(ranged.minWidth == 10)
        #expect(ranged.idealWidth == 20)
        #expect(ranged.maxWidth == 30)
    }
}

/// The stdlib protocol-extension sweep (BinaryInteger & friends expand to
/// their concrete carriers) — isMultiple(of:) gated FoodTruck's DateBins
/// binRange computation; contract types resolve Self -> carrier.
@Suite struct StdlibNumericMemberTests {
    @MainActor
    @Test func isMultipleMatchesNative() throws {
        let source = """
        let yes = 9.isMultiple(of: 3)
        let no = 10.isMultiple(of: 3)
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("yes")?.boolValue == true)
        #expect(interpreter.globals.lookup("no")?.boolValue == false)
    }
}
