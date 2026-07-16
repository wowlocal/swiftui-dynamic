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
}
