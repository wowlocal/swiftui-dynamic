import Testing
@testable import SwiftInterpreter

@Suite struct GeneratedCollectionDefaultTests {
    @Test func generatedIndexMotionServesInterpretedCollection() throws {
        let source = """
        struct Bytes: RandomAccessCollection {
            typealias Index = Int
            typealias Element = Int
            typealias SubSequence = Bytes

            let storage: [Int]
            let lower: Int
            let upper: Int

            var startIndex: Int { lower }
            var endIndex: Int { upper }

            subscript(position: Int) -> Int { storage[position] }
            subscript(bounds: Range<Int>) -> Bytes {
                Bytes(storage: storage, lower: bounds.lowerBound,
                      upper: bounds.upperBound)
            }
        }

        let bytes = Bytes(storage: [40, 41, 42], lower: 0, upper: 3)
        bytes[bytes.index(after: bytes.startIndex)]
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 41)
    }

    @Test func generatedFirstProjectionServesInterpretedCollection() throws {
        let source = """
        struct Window: RandomAccessCollection {
            let storage: [Int]
            var startIndex: Int { 1 }
            var endIndex: Int { 3 }

            func index(after value: Int) -> Int { value + 1 }
            subscript(position: Int) -> Int { storage[position] }
        }

        Window(storage: [10, 20, 30, 40]).first ?? -1
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 20)
    }

    @Test func generatedOptionalLastRemovalMutatesAndPreservesDynamicType() throws {
        let source = """
        class Node {}
        final class Element: Node {}
        final class TextNode: Node {
            func wholeTextSlice() -> Int { 1 }
        }

        var stack: [Node] = [Element()]
        var result = 0
        while let node = stack.popLast() {
            if let textNode = node as? TextNode {
                result = textNode.wholeTextSlice()
            } else {
                result = stack.isEmpty ? 42 : -1
            }
        }
        result
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 42)
    }

    @Test func generatedOptionalLastRemovalReturnsNilWhenEmpty() throws {
        let source = """
        var values: [Int] = []
        values.popLast() == nil
        """

        let value = try Interpreter().run(source: source)
        #expect(value.boolValue == true)
    }
}
