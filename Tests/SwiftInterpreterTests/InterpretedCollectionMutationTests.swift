import Testing
@testable import SwiftInterpreter

@MainActor
@Suite("Interpreted collection mutation")
struct InterpretedCollectionMutationTests {
    @Test func endpointRemovalMutatesNativeCollectionCarriers() throws {
        let source = #"""
        var text = "abcd"
        let textLast = text.removeLast()
        let textFirst = text.removeFirst()

        var values = [1, 2, 3, 4]
        let valueLast = values.removeLast()
        let valueFirst = values.removeFirst()

        "\(textFirst)\(textLast)|\(text)|\(valueFirst)\(valueLast)|\(values.count)|\(values[0])"
        """#

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "ad|bc|14|2|2")
    }

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
