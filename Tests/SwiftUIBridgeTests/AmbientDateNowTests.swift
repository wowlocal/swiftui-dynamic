import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck donuts-gallery drift: `startOfDay(for: .now)` — the bare
/// `.now` marker in a Date ARGUMENT position resolved through the
/// bridge's dateArg to the WALL CLOCK, bypassing the program's
/// `extension Date { static var now }` shadow (the frozen clock). The
/// ambient provider (installed per run when the shadow exists) routes
/// every dateArg-style coercion through the program's value.
@Suite struct AmbientDateNowTests {
    @MainActor
    @Test func dateByAddingComponentsAndWeekend() throws {
        setenv("FOODTRUCK_FROZEN_NOW", "1784228400", 1)
        defer { unsetenv("FOODTRUCK_FROZEN_NOW") }
        let source = """
        extension Date {
            static var now: Date {
                Date(timeIntervalSince1970: 1784228400)
            }
        }
        let startDate = Calendar.current.startOfDay(for: .now)
        let day = Calendar.current.date(byAdding: DateComponents(day: -60), to: startDate)!
        let weekend = Calendar.current.isDateInWeekend(day)
        let stamp = day.timeIntervalSince1970
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        let nativeStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1784228400))
        let nativeDay = Calendar.current.date(byAdding: DateComponents(day: -60), to: nativeStart)!
        print("PROBE interp-stamp=", interpreter.globals.lookup("stamp") ?? "nil",
              "native-stamp=", nativeDay.timeIntervalSince1970,
              "interp-weekend=", interpreter.globals.lookup("weekend") ?? "nil",
              "native-weekend=", Calendar.current.isDateInWeekend(nativeDay))
        #expect(interpreter.globals.lookup("stamp")?.doubleValue == nativeDay.timeIntervalSince1970)
        #expect(interpreter.globals.lookup("weekend")?.boolValue == Calendar.current.isDateInWeekend(nativeDay))
    }
}
