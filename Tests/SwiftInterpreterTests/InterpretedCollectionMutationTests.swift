import Testing
@testable import SwiftInterpreter

@MainActor
@Suite("Interpreted collection mutation")
struct InterpretedCollectionMutationTests {
    @Test func appendContentsOfMaterializesInterpretedCollection() throws {
        let source = """
        struct Slice: RandomAccessCollection {
            let storage: [Int]
            let lower: Int
            let upper: Int

            var startIndex: Int { lower }
            var endIndex: Int { upper }

            subscript(position: Int) -> Int {
                return storage[position]
            }
        }

        var values = [1]
        values.append(contentsOf: Slice(
            storage: [10, 20, 30, 40], lower: 1, upper: 3))
        values[0] + values[1] + values[2]
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 51)
    }
}
