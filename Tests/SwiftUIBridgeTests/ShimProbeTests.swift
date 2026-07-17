import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct ShimProbeTests {
    @MainActor
    @Test func realShim() throws {
        setenv("FOODTRUCK_FROZEN_NOW", "1784228400", 1)
        defer { unsetenv("FOODTRUCK_FROZEN_NOW") }
        let source = """
        nonisolated(unsafe) var __harnessRandomState = 0
        extension Double {
            static func random(in range: ClosedRange<Double>) -> Double {
                if __harnessRandomState == 0 {
                    if ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"] != nil {
                        __harnessRandomState = 1
                    } else {
                        __harnessRandomState = Int(Date(timeIntervalSinceNow: 0).timeIntervalSince1970 * 1000) % 2147483647 + 1
                    }
                }
                __harnessRandomState = (__harnessRandomState * 1103515245 + 12345) % 2147483648
                let unit = Double(__harnessRandomState) / 2147483648.0
                return range.lowerBound + unit * (range.upperBound - range.lowerBound)
            }
        }
        func olderDate(_ base: Date) -> Date {
            var date = base
            date = date.addingTimeInterval(-60 * .random(in: 5...30))
            return date
        }
        let d1 = olderDate(Date(timeIntervalSince1970: 1784228400))
        let d2 = olderDate(d1)
        let m1 = d1.timeIntervalSince1970
        let m2 = d2.timeIntervalSince1970
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        let m1 = interpreter.globals.lookup("m1")?.doubleValue ?? 0
        let m2 = interpreter.globals.lookup("m2")?.doubleValue ?? 0
        print("PROBE m1 offset-min:", (1784228400 - m1) / 60)
        print("PROBE m2 offset-min:", (1784228400 - m2) / 60)
    }
}
