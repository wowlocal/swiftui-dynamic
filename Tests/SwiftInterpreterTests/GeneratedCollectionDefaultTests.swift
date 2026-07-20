import Testing
@testable import SwiftInterpreter

@Suite struct GeneratedCollectionDefaultTests {
    /// Distilled from SwiftSoup's UTF-8 parser buffer growth. Native Swift
    /// prints `3`: reserving storage changes capacity, never logical contents.
    @Test func generatedNativeArrayVoidMutationPreservesContents() throws {
        let source = """
        var values = [1, 2]
        values.reserveCapacity(64)
        values.append(3)
        values.count
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 3)
    }

    @Test func generatedNativeDictionaryAndSetMutationsPreserveContents() throws {
        let source = """
        var dictionary = ["first": 1]
        dictionary.reserveCapacity(64)
        dictionary["second"] = 2

        var set: Set<Int> = [1]
        set.reserveCapacity(64)
        set.insert(2)

        "\\(dictionary.count)|\\(set.count)"
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "2|2")
    }

    @Test func generatedDictionaryKeyRemovalWritesBackAndReturnsValue() throws {
        let source = """
        final class Cache {
            var values = ["present": 7]

            func take(_ key: String) -> Int? {
                values.removeValue(forKey: key)
            }
        }

        let cache = Cache()
        let removed = cache.take("present") ?? -1
        let missing = cache.take("missing") == nil
        "\\(removed)|\\(cache.values.count)|\\(missing)"
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "7|0|true")
    }

    @Test func generatedNativeScalarVoidMutationUsesExplicitAndDefaultArguments() throws {
        let source = """
        var explicit = ["present": 1]
        explicit.removeAll(keepingCapacity: true)
        var defaulted = ["present": 2]
        defaulted.removeAll()
        "\\(explicit.count)|\\(defaulted.count)"
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "0|0")
    }

    @Test func generatedWritableStringCollectionViewWritesBack() throws {
        let source = """
        func copiedScalars<S: Sequence>(_ scalars: S) -> String
        where S.Iterator.Element == UnicodeScalar {
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars)
            return text
        }

        copiedScalars("A⭕".unicodeScalars)
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "A⭕")
    }

    @Test func generatedForwardIndexSearchPreservesStringIndices() throws {
        let source = """
        let text = "p.quote-inline"
        let dot = text.firstIndex(of: ".")!
        let quote = text.firstIndex(where: { $0 == "q" })!
        "\\(text.distance(from: text.startIndex, to: dot))|"
            + "\\(text.distance(from: text.startIndex, to: quote))"
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "1|2")
    }

    @Test func generatedNativeIndexMotionPreservesCarrierIndices() throws {
        let source = """
        let text = "p.quote-inline"
        let dot = text.firstIndex(of: ".")!
        let afterDot = text.index(after: dot)
        let beforeAfter = text.index(before: afterDot)
        let jumped = text.index(text.startIndex, offsetBy: 2)
        let limitedJump = text.index(
            text.startIndex, offsetBy: 2, limitedBy: text.endIndex)!
        let limitedMiss = text.index(
            text.startIndex, offsetBy: 20, limitedBy: text.endIndex) == nil
        let values = [10, 20, 30]
        "\\(text.distance(from: text.startIndex, to: afterDot))|"
            + "\\(text.distance(from: text.startIndex, to: beforeAfter))|"
            + "\\(text.distance(from: text.startIndex, to: jumped))|"
            + "\\(text.distance(from: text.startIndex, to: limitedJump))|"
            + "\\(limitedMiss)|"
            + "\\(values.index(after: values.startIndex))|"
            + "\\(values.index(before: values.endIndex))|"
            + "\\(values.index(values.startIndex, offsetBy: 2))|"
            + "\\(values.index(values.startIndex, offsetBy: 2, limitedBy: values.endIndex)!)|"
            + "\\(values.index(values.startIndex, offsetBy: 4, limitedBy: values.endIndex) == nil)"
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "2|1|2|2|true|1|2|2|2|true")
    }

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

    @Test func generatedBooleanPropertyWinsBareAccessOverMethod() throws {
        let source = """
        final class Elements: RandomAccessCollection {
            typealias Index = Int
            typealias Element = Int

            let storage: [Int] = []
            var startIndex: Int { storage.startIndex }
            var endIndex: Int { storage.endIndex }
            subscript(position: Int) -> Int { storage[position] }

            func isEmpty() -> Bool { false }
        }

        let elements = Elements()
        "\\(elements.isEmpty)|\\(elements.isEmpty())"
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "true|false")
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

    @Test func generatedLastProjectionServesInterpretedCollection() throws {
        let source = """
        struct Window: RandomAccessCollection {
            let storage: [Int]
            var startIndex: Int { 1 }
            var endIndex: Int { 3 }

            func index(before value: Int) -> Int { value - 1 }
            subscript(position: Int) -> Int { storage[position] }
        }

        Window(storage: [10, 20, 30, 40]).last ?? -1
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 30)
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
