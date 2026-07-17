import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// Program extensions SHADOW imported statics, exactly like a same-module
/// declaration beats an import in compiled Swift. The FoodTruck frozen
/// clock rides this: both harnesses inject `extension Date { static var
/// now }` (env-gated) so R2/R3 captures compare across runs — the
/// builtin Date.now must NOT preempt the interpreted extension, on either
/// the qualified (`Date.now`) or annotation (`: Date = .now`) path.
@Suite struct InterpretedStaticShadowingTests {
    @MainActor
    @Test func interpretedDateNowExtensionShadowsHost() throws {
        setenv("FOODTRUCK_FROZEN_NOW", "1784228400", 1)
        defer { unsetenv("FOODTRUCK_FROZEN_NOW") }
        let source = """
        extension Date {
            static var now: Date {
                if let raw = ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"],
                   let epoch = TimeInterval(raw) {
                    return Date(timeIntervalSince1970: epoch)
                }
                return Date(timeIntervalSinceNow: 0)
            }
        }
        let stamp = Date.now.timeIntervalSince1970
        let viaImplicit: Date = .now
        let implicitStamp = viaImplicit.timeIntervalSince1970
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("stamp")?.doubleValue == 1784228400)
        #expect(interpreter.globals.lookup("implicitStamp")?.doubleValue == 1784228400)
    }

    /// The deterministic-random shim rides the same semantic with a static
    /// FUNC: `extension Double { static func random(in:) }` must beat the
    /// builtin on the qualified path AND on the implicit-member call inside
    /// a Double-typed argument (`addingTimeInterval(-60 * .random(in:))` —
    /// the exact SocialFeedContent shape).
    @MainActor
    @Test func interpretedStaticFuncShadowResolvesImplicitMemberCalls() throws {
        let source = """
        nonisolated(unsafe) var __state = 1
        extension Double {
            static func random(in range: ClosedRange<Double>) -> Double {
                __state = (__state * 1103515245 + 12345) % 2147483648
                let unit = Double(__state) / 2147483648.0
                return range.lowerBound + unit * (range.upperBound - range.lowerBound)
            }
        }
        let qualified = Double.random(in: 5...30)
        let viaContext = Date(timeIntervalSince1970: 0).addingTimeInterval(-60 * .random(in: 5...30))
        let offset = viaContext.timeIntervalSince1970
        struct FixedGen: RandomNumberGenerator {
            var v: UInt64 = 42
            mutating func next() -> UInt64 {
                v += 1
                return v
            }
        }
        var gen = FixedGen()
        var seededDelta = 0.0
        seededDelta -= .random(in: 60 ..< 180, using: &gen)
        let qualifiedSeeded = Double.random(in: 80.0 ... 120.0, using: &gen)
        let stateAfterSeeded = __state
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("qualified")?.doubleValue == 17.846751953475177)
        // The offset expectation is computed through native Foundation so
        // the pin asserts interp == native BIT-EXACTLY, including Date's
        // own epoch<->reference-date round-trip precision.
        let nativeOffset = Date(timeIntervalSince1970: 0)
            .addingTimeInterval(-60 * 9.393532581161708).timeIntervalSince1970
        #expect(interpreter.globals.lookup("offset")?.doubleValue == nativeOffset)
        // The SEEDED spelling (`.random(in:using:)` — OrderGenerator's
        // shape) must NOT be captured by the 1-arg program shadow: native
        // overload resolution picks the stdlib 2-arg. The LCG state pins
        // it — exactly two draws consumed, none by the seeded call.
        #expect(interpreter.globals.lookup("stateAfterSeeded")?.intValue == 377401575)
        #expect((interpreter.globals.lookup("seededDelta")?.doubleValue ?? 0) < 0)
        let qualifiedSeeded = interpreter.globals.lookup("qualifiedSeeded")?.doubleValue ?? 0
        #expect(qualifiedSeeded >= 80.0 && qualifiedSeeded < 120.0)
    }
}
