import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// LOOP.md scope quarantine: entitlement-gated services FAIL CLOSED —
/// headless native throws without the entitlement, and the app's own
/// catch keeps its sample data. Absorbing instead lets junk overwrite
/// state (FoodTruck's forecast .task blanked the chart on re-render).
@Suite struct EnvironmentalServiceTests {
    @MainActor
    @Test func weatherServiceCallThrowsAndCatchKeepsState() throws {
        let source = """
        final class Model {
            var entries: [Int] = [1, 2, 3]
            func refresh() async {
                do {
                    let weather = try await WeatherService.shared.weather(for: 1, including: 2)
                    entries = []
                    _ = weather
                } catch {
                    // native headless lands here — sample data survives
                }
            }
        }
        let model = Model()
        await model.refresh()
        let count = model.entries.count
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("count")?.intValue == 3,
                "WeatherService absorbed instead of throwing; state was overwritten")
    }
}
