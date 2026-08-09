import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck donuts-gallery drift: `startOfDay(for: .now)` — the bare
/// `.now` marker in a Date ARGUMENT position once resolved to the wall clock,
/// bypassing the program's `extension Date { static var now }` shadow (the
/// frozen clock). The task-bound evaluation context now routes every typed
/// bridge argument through the exact program entry that supplied the host
/// call.
@Suite struct AmbientDateNowTests {
    @MainActor
    @Test func dateFormatterUsesOrdinaryContextForMembersAndInitializers() throws {
        let source = """
        extension Date {
            static var reference: Date {
                Date(timeIntervalSince1970: 962409600)
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        let member = formatter.string(from: .reference)
        let initialized = formatter.string(
            from: .init(timeIntervalSince1970: 962409600))
        "\\(member)|\\(initialized)"
        """
        let interpreter = Interpreter(registry: ViewRegistry())

        #expect(try interpreter.run(source: source).stringValue == "2000|2000")
    }

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

    @MainActor
    @Test func escapedCallbackKeepsItsProgramStaticShadow() throws {
        let source = """
        extension Date {
            static var now: Date {
                Date(timeIntervalSince1970: 1784228400)
            }
        }
        func makeCallback() -> () -> Double {
            {
                Calendar.current.startOfDay(for: .now)
                    .timeIntervalSince1970
            }
        }
        makeCallback()
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        let value = try interpreter.run(source: source)
        let callback = try #require(value.closureValue)

        _ = try interpreter.run(source: "let newerProgram = true")
        let callbackValue = try interpreter.callHostCallback(
            callback, arguments: [])

        let expected = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1784228400))
            .timeIntervalSince1970
        #expect(callbackValue.doubleValue == expected)
    }
}
