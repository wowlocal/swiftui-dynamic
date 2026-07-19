import Foundation
import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

@Suite struct CollectionBackedBufferTests {
    @Test func genericHostConstructorDoesNotStealCollectionBackedBuffer() throws {
        let source = """
        final class Reader {
            let input: UnsafeBufferPointer<Int>

            init(_ values: [Int]) {
                var base: UnsafePointer<Int>? = nil
                values.withUnsafeBufferPointer { buffer in
                    base = buffer.baseAddress
                }
                input = UnsafeBufferPointer(
                    start: base, count: values.count)
            }
        }

        let reader = Reader([65, 66])
        reader.input[0] + reader.input[1]
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 131)
    }

    @Test func fixedWidthIntegerCursorRemainsAnArrayIndex() throws {
        let source = """
        let width: UInt8 = 1
        var cursor: Int = 0
        cursor += Int(width)
        [65, 66][cursor]
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 66)
    }

    @Test func absorbedOptionalImportRunsNilFallback() throws {
        let source = """
        if let value = unavailable_import() {
            1
        } else {
            2
        }
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 2)
    }

    @Test func collectionBackedBytePointerSupportsRawSearch() throws {
        let source = """
        import Darwin

        func probe(_ values: [UInt8]) -> Int {
            var base: UnsafePointer<UInt8>? = nil
            values.withUnsafeBufferPointer { buffer in
                base = buffer.baseAddress
            }
            let input = UnsafeBufferPointer(
                start: base, count: values.count)
            guard let pointer = input.baseAddress else { return -2 }
            let raw = UnsafeRawPointer(pointer.advanced(by: 0))
            let word = raw.load(as: UInt64.self)
            guard let found = memchr(pointer, Int32(90), values.count) else {
                return -1
            }
            let offset = Int(bitPattern: found) - Int(bitPattern: pointer)
            return offset * 100 + Int(word & 0xff)
        }

        var bytes = [UInt8](repeating: 65, count: 40)
        bytes[23] = 90
        probe(bytes)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 2_365)
    }

    @Test func chainedMemberSelectsReturnTypeOverload() throws {
        let source = """
        struct Bytes {
            let value: Int

            func decoded() -> Int {
                value + 1
            }
        }

        final class Reader {
            func slice(_ value: Int) -> String {
                "wrong"
            }

            func slice(_ value: Int) -> Bytes {
                Bytes(value: value)
            }
        }

        Reader().slice(41).decoded()
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 42)
    }

    @Test func chainedCollectionResultRetainsExtensionReceiverType() throws {
        let source = """
        extension ArraySlice where Element == UInt8 {
            func decoded() -> Int {
                reduce(0) { $0 * 10 + Int($1 - 48) }
            }
        }

        struct Bytes {
            func slice() -> ArraySlice<UInt8> {
                [52, 50]
            }
        }

        Bytes().slice().decoded()
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 42)
    }

    @Test func instanceOverloadFitsRuntimeArgumentType() throws {
        let source = """
        struct Scalar {
            let value: Int
        }

        final class Reader {
            func consume(_ scalar: Scalar) -> Int {
                scalar.value + 1_000
            }

            func consume(_ bytes: [Int]) -> Int {
                bytes[0]
            }
        }

        Reader().consume([61])
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 61)
    }

    @Test func mutatingSortExecutesElementComparator() throws {
        let source = """
        struct Item {
            let rank: Int
        }

        var items = [Item(rank: 2), Item(rank: 1)]
        items.sort { left, right in
            left.rank < right.rank
        }
        items[0].rank
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 1)
    }

    @Test func declaredCollectionTypeDispatchesExtensionOperator() throws {
        let source = """
        extension ArraySlice where Element == Int {
            static func < (lhs: ArraySlice<Int>, rhs: ArraySlice<Int>) -> Bool {
                lhs[0] < rhs[0]
            }
        }

        struct Item {
            let key: ArraySlice<Int>
        }

        func compare() -> Bool {
            let left = Item(key: [1])
            let right = Item(key: [2])
            return left.key < right.key
        }

        compare()
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.boolValue == true)
    }

    @Test func bitwiseComplementPreservesUInt64Width() throws {
        let source = """
        let value = UInt64(0)
        Int((~value) & UInt64(255))
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 255)
    }

    @Test func integerLiteralRetainsUInt64Magnitude() throws {
        let source = """
        let value: UInt64 = 0x8080808080808080
        Int((value >> UInt64(56)) & UInt64(255))
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 128)
    }

    @Test func collectionBackedPointerSupportsTypedSubscript() throws {
        let source = """
        func second(_ values: [UInt8]) -> Int {
            var result = -1
            values.withUnsafeBufferPointer { buffer in
                if let pointer = buffer.baseAddress {
                    result = Int(pointer[1])
                }
            }
            return result
        }

        second([41, 42])
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 42)
    }

    @Test func loadedUInt64SupportsZeroByteDetection() throws {
        let source = """
        func firstMatchingWord(_ values: [UInt8], _ target: UInt8) -> Int {
            var result = -1
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let repeatedByteMask: UInt64 = 0x0101010101010101
                let highBitRepeatMask: UInt64 = 0x8080808080808080
                let targetWord = UInt64(target)
                var index = 0
                while index <= values.count - 8 {
                    let word = UnsafeRawPointer(base.advanced(by: index))
                        .load(as: UInt64.self)
                    let x = word ^ (targetWord &* repeatedByteMask)
                    if ((x &- repeatedByteMask) & ~x & highBitRepeatMask) != 0 {
                        result = index
                        break
                    }
                    index &+= 8
                }
            }
            return result
        }

        var bytes = [UInt8](repeating: 65, count: 128)
        bytes[23] = 90
        firstMatchingWord(bytes, 90)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 16)
    }

    @Test func nullableScalarGetterReadsCollectionBackedPointer() throws {
        let source = """
        final class Reader {
            let input: UnsafeBufferPointer<UInt8>
            var position: Int
            let end: Int

            init(_ values: [UInt8], position: Int) {
                var base: UnsafePointer<UInt8>? = nil
                values.withUnsafeBufferPointer { buffer in
                    base = buffer.baseAddress
                }
                input = UnsafeBufferPointer(
                    start: base, count: values.count)
                self.position = position
                end = values.count
            }

            func currentByte() -> UInt8? {
                guard position < end else { return nil }
                return input[position]
            }
        }

        let present = Reader([41, 42], position: 1).currentByte()
        let missing = Reader([41, 42], position: 2).currentByte()
        Int(present ?? 0) + Int(missing ?? 0)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 42)
    }

    /// Distilled from SwiftSoup's `UInt8.isWhitespace` getter in String.swift.
    @Test func scalarSwitchGetterKeepsTheCurrentReceiver() throws {
        let source = """
        final class ASCII {
            static let tab: UInt8 = 9
            static let space: UInt8 = 32
        }

        extension UInt8 {
            var isSeparator: Bool {
                switch self {
                case ASCII.tab, ASCII.space:
                    return true
                default:
                    return false
                }
            }
        }

        var score = 0
        let bytes: [UInt8] = [32, 65, 9]
        bytes.withUnsafeBufferPointer { input in
            if input[0].isSeparator { score += 1 }
            if input[1].isSeparator { score += 10 } else { score += 100 }
            if input[2].isSeparator { score += 1_000 }
        }
        score
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 1_101)
    }

    /// Distilled from SwiftSoup's `StringBuilder.toString()` storage shape.
    @Test func stringDecodingInitializerAcceptsUTF8Collection() throws {
        let source = """
        open class Buffer {
            private var internalBuffer: [UInt8] = []
            private var size: Int = 0

            init(string: String? = nil) {
                if let string, !string.isEmpty {
                    internalBuffer.append(contentsOf: string.utf8)
                    size = internalBuffer.count
                }
            }

            open func toString() -> String {
                String(
                    decoding: internalBuffer[0..<size],
                    as: UTF8.self)
            }
            var count: Int { size }
        }

        let buffer = Buffer(string: "probe")
        "\\(buffer.count)|\\(buffer.toString())"
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.stringValue == "5|probe")
    }

    /// Distilled from SwiftSoup's String.utf8Array fast-path fallback.
    @Test func unavailableContiguousStorageFallsBackToCollection() throws {
        let source = """
        extension String {
            var copiedUTF8: [UInt8] {
                if let output = utf8.withContiguousStorageIfAvailable({
                    buffer -> [UInt8] in
                    let count = buffer.count
                    if count == 0 { return [] }
                    guard let source = buffer.baseAddress else {
                        return Array(utf8)
                    }
                    var output = [UInt8](repeating: 0, count: count)
                    output.withUnsafeMutableBytes { destination in
                        if let destination = destination.baseAddress {
                            destination.copyMemory(
                                from: source, byteCount: count)
                        }
                    }
                    return output
                }) {
                    return output
                }
                return Array(utf8)
            }
        }

        String(decoding: "probe".copiedUTF8, as: UTF8.self)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.stringValue == "probe")
    }

    @Test func inheritedMethodInvokesOverrideThroughImplicitSelf() throws {
        let source = """
        class Base {
            func process(_ value: Int) -> Int {
                return -1
            }

            func run(_ value: Int) -> Int {
                return process(value)
            }
        }

        final class Child: Base {
            override func process(_ value: Int) -> Int {
                value + 1
            }
        }

        Child().run(41)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 42)
    }

    @Test func staticOverloadFitsRuntimeArgumentTypes() throws {
        let source = """
        struct Parser {
            static func parse(_ input: [Int], _ base: [Int]) -> String {
                "wrong"
            }

            static func parse(_ input: String, _ base: String) -> String {
                input + base
            }
        }

        Parser.parse("right", "")
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.stringValue == "right")
    }

    /// Distilled from `Entities.EscapeMode.init`: a nested type can refer to
    /// static members of its lexically enclosing type without qualification.
    @Test func nestedTypeInitializerSeesEnclosingStaticMember() throws {
        let source = """
        final class Entities {
            private static let radix = 36

            final class EscapeMode {
                let decoded: Int

                init(_ value: Int) {
                    decoded = value + radix
                }
            }
        }

        Entities.EscapeMode(6).decoded
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 42)
    }

    /// Distilled from SwiftSoup's `ByteSlice`: the standard library supplies
    /// integer-index motion for a matching RandomAccessCollection conformer.
    @Test func integerIndexedCollectionUsesGeneratedDefaultIndexMotion() throws {
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

            subscript(position: Int) -> Int {
                storage[position]
            }

            subscript(bounds: Range<Int>) -> Bytes {
                Bytes(storage: storage, lower: bounds.lowerBound,
                      upper: bounds.upperBound)
            }
        }

        let bytes = Bytes(storage: [40, 41, 42], lower: 0, upper: 3)
        bytes[bytes.index(after: bytes.startIndex)]
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 41)
    }

    /// Distilled from HtmlTreeBuilder's state-machine reprocessing: an active
    /// overload remains recursively callable when every inactive sibling has
    /// a different argument shape.
    @Test func overloadedMethodReentersItsOwnCallShape() throws {
        let source = """
        final class StateMachine {
            func process(_ value: Int) -> Int {
                if value == 0 { return 42 }
                return process(value - 1)
            }

            func process(_ value: Int, _ state: Int) -> Int {
                -1
            }
        }

        StateMachine().process(1)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 42)
    }

    @Test func diagnosticSwiftSoupParsesNonASCIIText() throws {
        let root = FileManager.default.currentDirectoryPath
        let files = ProjectMaterial.swiftFiles(
            under: root
                + "/Examples/IceCubesNativeTwin/.build/checkouts/SwiftSoup/Sources")
        let source = ProjectMaterial.mergedSource(
            files: files,
            sourceModules: Dictionary(uniqueKeysWithValues: files.map {
                ($0, "SwiftSoup")
            })) + """

        // swift-interpreter-module SwiftSoup
        let document = try SwiftSoup.parse("<p>é</p>")
        try document.text()
        """

        do {
            let value = try Interpreter(registry: TraceRegistry()).run(source: source)
            #expect(value.stringValue == "é")
        } catch let runtime as RuntimeError {
            let lines = source.split(
                separator: "\n", omittingEmptySubsequences: false)
            if runtime.line > 0, runtime.line <= lines.count {
                print("@@runtime-line|\(runtime.line)|\(lines[runtime.line - 1])")
            }
            throw runtime
        }
    }

}
