import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// The sales-history falloff (`1 - pow(offset/count, falloff)`) feeds
/// Int() floors: pow must match libm bit-for-bit or day counts drift.
@Suite struct PowBitExactTests {
    @MainActor
    @Test func powMatchesLibmBitForBit() throws {
        let source = """
        let a = pow(3.0 / 14.0, 2.4)
        let b = pow(0.5714285714285714, 2.4)
        let c = 1 - pow(7.0 / 14.0, 2.4)
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("a")?.doubleValue == pow(3.0 / 14.0, 2.4),
                "a: \(String(describing: interpreter.globals.lookup("a"))) vs \(pow(3.0 / 14.0, 2.4))")
        #expect(interpreter.globals.lookup("b")?.doubleValue == pow(0.5714285714285714, 2.4))
        #expect(interpreter.globals.lookup("c")?.doubleValue == 1 - pow(7.0 / 14.0, 2.4))
    }
}
