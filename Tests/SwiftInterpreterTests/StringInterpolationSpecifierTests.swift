import Testing
@testable import SwiftInterpreter

@Suite struct StringInterpolationSpecifierTests {
    @Test func localizedCStyleSpecifiersMatchNativeSwift() throws {
        let result = try Interpreter().run(source: #"""
        let number = 1
        let order = String(localized: ("#\(12)\(number, specifier: "%02d")"))
        let formats = String(localized: ("\(7, specifier: "%03d")|\(3.14159, specifier: "%.2f")|\(255, specifier: "%02X")"))
        "\(order)|\(formats)"
        """#)

        #expect(result.stringValue == "#1201|007|3.14|FF")
    }

    @Test func valueAndSpecifierEvaluateOnceInSourceOrder() throws {
        let result = try Interpreter().run(source: #"""
        var events = ""
        func value() -> Int {
            events += "v"
            return 3
        }
        func specifier() -> String {
            events += "s"
            return "%02d"
        }

        let text = String(localized: ("\(value(), specifier: specifier())"))
        "\(text)|\(events)"
        """#)

        #expect(result.stringValue == "03|vs")
    }

    @Test func specifierRequiresAStringAtTheDynamicBoundary() {
        #expect(throws: RuntimeError.self) {
            try Interpreter().run(source: #"String(localized: ("\(3, specifier: 2)"))"#)
        }
    }
}
