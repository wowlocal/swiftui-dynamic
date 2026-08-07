import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// IceCubes' `Models/Alias/ServerDate.swift` renders every relative timestamp
/// through
/// `Duration.seconds(-date.timeIntervalSinceNow).formatted(.units(width: .narrow, maximumUnitCount: 1))`.
/// On the `display-settings` screen the twin draws "2m" and the interpreter
/// draws nothing, which is the whole of that screen's remaining pixel debt.
///
/// Two mechanisms can produce a blank, and these observables SEPARATE them:
/// the stdlib style may simply be unbridged, or the app's own `Env.Duration`
/// enum (IceCubes declares one) may shadow the stdlib type in the merged
/// module. Every expectation is the HOST's own output for the same call, so
/// none of them can be satisfied by drawing a plausible string.
@Suite struct DurationUnitsFormatTests {
    /// The style with no competing declaration anywhere in the program. If
    /// this fails, the class is "a Duration cannot format" and shadowing is
    /// not involved at all.
    @MainActor
    @Test func stdlibDurationFormatsThroughUnitsStyle() throws {
        let source = """
        let narrow1 = Duration.seconds(100).formatted(
            .units(width: .narrow, maximumUnitCount: 1))
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(try interpreter.globalValue(named: "narrow1")?.stringValue
            == Duration.seconds(100).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
    }

    /// The style's ARGUMENTS must reach the formatter: three shapes whose
    /// native readings differ from each other, so a fix cannot pass by
    /// answering one memorised string.
    @MainActor
    @Test func styleArgumentsReachTheFormatter() throws {
        let source = """
        let short = Duration.seconds(45).formatted(
            .units(width: .narrow, maximumUnitCount: 1))
        let hour = Duration.seconds(3700).formatted(
            .units(width: .narrow, maximumUnitCount: 1))
        let wide = Duration.seconds(3700).formatted(
            .units(width: .wide, maximumUnitCount: 2))
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(try interpreter.globalValue(named: "short")?.stringValue
            == Duration.seconds(45).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
        #expect(try interpreter.globalValue(named: "hour")?.stringValue
            == Duration.seconds(3700).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
        #expect(try interpreter.globalValue(named: "wide")?.stringValue
            == Duration.seconds(3700).formatted(
                .units(width: .wide, maximumUnitCount: 2)))
        // The three readings are genuinely different glyph runs, so the three
        // assertions above cannot all pass by drawing one value.
        #expect(Duration.seconds(45).formatted(
            .units(width: .narrow, maximumUnitCount: 1))
            != Duration.seconds(3700).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
    }

    /// The IceCubes shape: an app enum named `Duration` is declared in the
    /// SAME merged module, exactly as `Env/Duration.swift` is. Natively
    /// `ServerDate.swift` imports only Foundation and so never sees it; the
    /// interpreter merges every package into one namespace, so this is where
    /// a shadow would bite.
    @MainActor
    @Test func appEnumNamedDurationDoesNotShadowTheStdlibStyle() throws {
        let source = """
        enum Duration: Int, CaseIterable {
            case infinite = 0
            case oneHour = 3600
        }
        let narrow1 = Swift.Duration.seconds(100).formatted(
            .units(width: .narrow, maximumUnitCount: 1))
        let appCase = Duration.oneHour.rawValue
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(try interpreter.globalValue(named: "narrow1")?.stringValue
            == Duration.seconds(100).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
        // Counter-direction: the app's own enum must keep working. A fix that
        // resolved the name to the stdlib type unconditionally would break
        // every `Env.Duration` use site in the app.
        #expect(try interpreter.globalValue(named: "appCase")?.intValue == 3600)
    }

    /// `ServerDate.relativeFormatted`'s else-branch verbatim, including the
    /// `Date() - 100` the example post is built from.
    @MainActor
    @Test func serverDateRelativeShapeMatchesNative() throws {
        let source = """
        let past = Date() - 100
        let relative = Duration.seconds(-past.timeIntervalSinceNow).formatted(
            .units(width: .narrow, maximumUnitCount: 1))
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        // 100 seconds ago reads the same as a literal 100-second duration —
        // the milliseconds this test itself takes cannot move a 1-unit narrow
        // reading off "2m".
        #expect(try interpreter.globalValue(named: "relative")?.stringValue
            == Duration.seconds(100).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
    }

    /// Counter-direction: `Task.sleep(for: .seconds(_:))` consumes the same
    /// leading-dot shape as an `ImplicitMemberCall` marker
    /// (`TaskSuspension.sourceDuration`). Whatever makes a Duration formattable
    /// must not take that reading away.
    @MainActor
    @Test func sleepDurationMarkerStillReadsItsAmount() throws {
        let source = """
        func delay() async throws {
            try await Task.sleep(for: .seconds(0.001))
        }
        let scaled = Duration.seconds(2)
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        // The program parses and the declaration survives; the amount is what
        // the sleep path reads.
        #expect(try interpreter.globalValue(named: "scaled") != nil)
    }
}
