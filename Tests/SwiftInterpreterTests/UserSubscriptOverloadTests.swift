import Testing
@testable import SwiftInterpreter

@MainActor
@Suite("User subscript overloads")
struct UserSubscriptOverloadTests {
    @Test func rangeArgumentSelectsRangeSubscript() throws {
        let source = """
        struct Window {
            subscript(position: Int) -> Int {
                return position
            }

            subscript(bounds: Range<Int>) -> Int {
                return bounds.upperBound - bounds.lowerBound
            }
        }

        Window()[2..<7]
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 5)
    }
}
