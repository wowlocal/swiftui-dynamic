import Charts
import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck truck-row axis class: `DateBins(unit:by:range:).thresholds`
/// must hand the REAL threshold dates to AxisMarks. Before the Charts
/// sweep landed in BridgeGen, `.thresholds` absorbed under
/// assumesCompiledImports and AxisMarks silently fell back to `.automatic`
/// — 6-hourly labels where native renders 3-hourly.
@Suite struct GeneratedChartsMemberTests {
    @MainActor
    @Test func dateBinsThresholdsMatchNative() throws {
        let source = """
        let start = Date(timeIntervalSince1970: 1784192400)
        let range = start...start.addingTimeInterval(24 * 3600)
        let bins = DateBins(unit: .hour, by: 3, range: range)
        let n = bins.thresholds.count
        let first = bins.thresholds.first!.timeIntervalSince1970
        let last = bins.thresholds[n - 1].timeIntervalSince1970
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        let start = Date(timeIntervalSince1970: 1784192400)
        let native = DateBins(unit: .hour, by: 3, range: start...start.addingTimeInterval(24 * 3600)).thresholds
        #expect(interpreter.globals.lookup("n")?.intValue == native.count)
        #expect(interpreter.globals.lookup("first")?.doubleValue == native.first?.timeIntervalSince1970)
        #expect(interpreter.globals.lookup("last")?.doubleValue == native.last?.timeIntervalSince1970)
    }
}
