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

    @Test func absorbedOptionalMemberOnConcreteHostRetainsOpaqueValue() throws {
        let source = """
        import Foundation

        if let value = Date().unavailablePackageExtension() {
            1
        } else {
            2
        }
        """

        let value = try Interpreter(registry: TraceRegistry()).run(
            source: source, lazyTopLevelGlobals: true)
        #expect(value.intValue == 1)
    }

    @Test func absorbedImportedConstructorRetainsOpaqueValue() throws {
        let source = """
        if let value = ExternalPackageClient() {
            1
        } else {
            2
        }
        """

        let value = try Interpreter(registry: TraceRegistry()).run(
            source: source, lazyTopLevelGlobals: true)
        #expect(value.intValue == 1)
    }

    @Test func absorbedOptionalMemberOnImportedHostRetainsOpaqueValue() throws {
        let source = """
        let client = ExternalPackageClient()
        if let value = client.currentSession {
            1
        } else {
            2
        }
        """

        let value = try Interpreter(registry: TraceRegistry()).run(
            source: source, lazyTopLevelGlobals: true)
        #expect(value.intValue == 1)
    }

    @Test func absorbedOptionalMemberOnUnresolvedImportRunsNilFallback() throws {
        let source = """
        if let value = unavailable_import().currentSession {
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

    /// Typed pointers advance by elements for every standard offset spelling;
    /// the same capability advances raw-pointer views by bytes.
    @Test func collectionBackedPointerSupportsOffsetOperators() throws {
        let source = """
        func offsetScore(_ values: [Int]) -> Int {
            var result = -1
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                result = (base + 2).pointee
                    + (1 + base).pointee
                    + ((base + 2) - 1).pointee
            }
            return result
        }

        offsetScore([10, 20, 42])
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 82)
    }

    /// Raw-buffer rebinding is discovered from the standard-library
    /// interface and preserves the carrier's bytes and indexing semantics.
    @Test func collectionBackedRawBufferSupportsMemoryBinding() throws {
        let source = """
        var result = -1
        let bytes: [UInt8] = [41, 42]
        bytes.withUnsafeBufferPointer { typed in
            let raw = UnsafeRawBufferPointer(
                start: typed.baseAddress, count: typed.count)
            let rebound = raw.bindMemory(to: UInt8.self)
            result = Int(rebound[1])
        }
        result
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

    /// An enum associated-value pattern retains the payload's declared array
    /// element type through a scoped buffer and a derived buffer window.
    @Test func enumPayloadBufferRetainsItsElementType() throws {
        let source = """
        extension UInt8 {
            var isMarker: Bool { self == 65 }
        }

        enum Backing {
            case array([UInt8])
        }

        func hasMarker(_ backing: Backing) -> Bool {
            switch backing {
            case .array(let array):
                return array.withUnsafeBufferPointer { buffer in
                    let slice = UnsafeBufferPointer(
                        start: buffer.baseAddress, count: array.count)
                    guard let base = slice.baseAddress else { return false }
                    let byte = base[0]
                    return byte.isMarker
                }
            }
        }

        hasMarker(.array([65]))
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.boolValue == true)
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

    @Test func mutableBufferPointerUpdateWritesBackToArray() throws {
        let source = """
        var destination: [UInt8] = [65, 66, 67, 68]
        let replacement: [UInt8] = [120, 121]
        destination.withUnsafeMutableBufferPointer { destinationBuffer in
            replacement.withUnsafeBufferPointer { sourceBuffer in
                guard let destinationBase = destinationBuffer.baseAddress,
                      let sourceBase = sourceBuffer.baseAddress else { return }
                destinationBase.advanced(by: 1).update(
                    from: sourceBase, count: sourceBuffer.count)
            }
        }
        String(decoding: destination, as: UTF8.self)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.stringValue == "AxyD")
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

    @Test func optionalBindingRetainsArraySliceElementType() throws {
        let source = """
        extension UInt8 {
            var whitespaceProbe: Bool { self == 32 }
        }

        let bytes: [UInt8] = [32]
        let slice: ArraySlice<UInt8> = bytes[0..<bytes.count]
        if let first = slice.first {
            first.whitespaceProbe
        } else {
            false
        }
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.boolValue == true)
    }

    /// An interpreted collection can overload its subscript by index shape.
    /// The selected getter's declared result type must survive the integer
    /// runtime carrier both inline and through an inferred local binding.
    @Test func overloadedUserSubscriptRetainsScalarResultType() throws {
        let source = """
        extension UInt8 {
            var whitespaceProbe: Bool { self == 32 }
        }

        struct Bytes {
            subscript(position: Int) -> UInt8 { 32 }
            subscript(bounds: Range<Int>) -> Bytes { self }
        }

        let bytes = Bytes()
        let first = bytes[0]
        (first.whitespaceProbe ? 10 : 0)
            + (bytes[1].whitespaceProbe ? 1 : 0)
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.intValue == 11)
    }

    @Test func enumPayloadBindingRetainsByteArrayElementType() throws {
        let source = """
        enum Backing {
            case array([UInt8])
        }

        let backing = Backing.array([65, 66, 67])
        switch backing {
        case .array(let bytes):
            bytes.withUnsafeBufferPointer { buffer in
                let raw = UnsafeRawBufferPointer(
                    start: UnsafeRawPointer(buffer.baseAddress),
                    count: buffer.count)
                let rebound = raw.bindMemory(to: UInt8.self)
                return String(decoding: rebound, as: UTF8.self)
            }
        }
        """

        let value = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(value.stringValue == "ABC")
    }

    /// Trimmed from the first recorded IceCubes public status. SwiftSoup's
    /// whitespace path reads `ArraySlice<UInt8>.first`; optional binding must
    /// preserve that declared element type for UInt8 extension dispatch.
    @Test func swiftSoupWhitespaceKeepsArraySliceElementType() throws {
        let text = try swiftSoupText("<p>Des familles</p>")
        #expect(text == "Des familles")
    }

    /// The first recorded IceCubes status adds a leading multi-byte symbol to
    /// the now-covered whitespace path. Keep the next parser boundary pinned
    /// to the actual replay bytes rather than a fabricated Unicode sample.
    @Test func swiftSoupParsesRecordedLeadingSymbolText() throws {
        let text = try swiftSoupText(
            "<p>⭕Des familles ont été prises dans des nuages de gaz "
                + "lacrymogènes lancés par la police lors d’un tournoi de foot.</p>")
        #expect(text == "⭕Des familles ont été prises dans des nuages de gaz "
            + "lacrymogènes lancés par la police lors d’un tournoi de foot.")
    }

    /// IceCubes decodes multiple HTML values through a recursive mutating
    /// SwiftSoup traversal; later values must not inherit earlier DOM bytes.
    @Test func swiftSoupMarkdownDecoderPreservesSequentialHTMLValues() throws {
        let firstExpected = "⭕Des familles ont été prises dans des nuages de gaz "
            + "lacrymogènes lancés par la police lors d’un tournoi de foot."
        let secondHTML = "🌉 <a href=\"https://fed.brid.gy/bsky/antyfaszysta.bsky.social\" "
            + "rel=\"nofollow noopener\" target=\"_blank\">bridged</a> from 🦋 "
            + "<a href=\"https://bsky.app/profile/antyfaszysta.bsky.social\" "
            + "rel=\"nofollow noopener\" target=\"_blank\">"
            + "antyfaszysta.bsky.social</a>"
        let encoded = String(data: try JSONEncoder().encode([
            "first": "<p>" + firstExpected + "</p>",
            "second": secondHTML,
        ]), encoding: .utf8)!
        let htmlStringURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IceCubesHTMLString.swift")
        let htmlStringSource = try String(
            contentsOf: htmlStringURL,
            encoding: .utf8)
        let value = try swiftSoupEvaluation(
            "", additionalSource: htmlStringSource,
            additionalSourceModule: "Models", suffix: """
            import Models

            struct Inputs: Decodable {
                let first: HTMLString
                let second: HTMLString
            }
            let inputs = try JSONDecoder().decode(
                Inputs.self,
                from: \(String(reflecting: encoded)).data(using: .utf8)!)
            inputs.first.asMarkdown + "|" + inputs.second.asMarkdown
            """, suffixModule: "IceCubesMarkdownRegressionProbe")
        #expect(value.stringValue == firstExpected
            + "|🌉 [bridged](https://fed.brid.gy/bsky/antyfaszysta.bsky.social)"
            + " from 🦋 [antyfaszysta.bsky.social]"
            + "(https://bsky.app/profile/antyfaszysta.bsky.social)")
    }

    /// A linked multi-paragraph status must finish the complete HTMLString
    /// initializer. Falling into its catch after Markdown traversal leaves
    /// `asRawText` equal to the original markup and can falsely classify a
    /// short visible post as a long one.
    @Test func swiftSoupHTMLStringSanitizesLinkedParagraphRawText() throws {
        let root = FileManager.default.currentDirectoryPath
        let fixtureURL = URL(fileURLWithPath: root)
            .appendingPathComponent(
                "Fixtures/mastodon-public-timeline/"
                    + "api_v1_timelines_public.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try #require(
            JSONSerialization.jsonObject(with: fixtureData)
                as? [[String: Any]])
        let html = try #require(fixture[1]["content"] as? String)
        let encoded = String(
            data: try JSONEncoder().encode(["content": html]),
            encoding: .utf8)!
        let htmlStringURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IceCubesHTMLString.swift")
        let htmlStringSource = try String(
            contentsOf: htmlStringURL,
            encoding: .utf8)
        let value = try swiftSoupEvaluation(
            "", additionalSource: htmlStringSource,
            additionalSourceModule: "Models", suffix: """
            import Models

            struct Input: Decodable {
                let content: HTMLString
            }
            let input = try JSONDecoder().decode(
                Input.self,
                from: \(String(reflecting: encoded)).data(using: .utf8)!)
            input.content.asRawText
            """, suffixModule: "LinkedParagraphRegressionProbe")
        let rawText = try #require(value.stringValue)
        #expect(rawText.contains("NATO: Revólver oferecido"))
        #expect(!rawText.contains("<p>"))
        #expect(rawText.unicodeScalars.count < 750)
    }

    /// A parsed HTML fragment returns nodes, not the integer indices used
    /// internally while maintaining the child array.
    @Test func swiftSoupFragmentReturnsNodeCollection() throws {
        let value = try swiftSoupEvaluation(
            "<p>alpha</p>", suffix: """
            let paragraph = try document.select("p").first()!
            let nodes = try Parser.parseFragment("\\n\\n", paragraph.parent(), [])
            nodes.count * 100 + (nodes[0] is Node ? 1 : 0)
            """)
        #expect(value.intValue == 101)
    }

    /// `Node.reparentChild` compares its weak optional parent with `self`
    /// before removing the fragment node. Exercise that public DOM path, not
    /// only the lower-level fragment parser that produces the node collection.
    @Test func swiftSoupAfterReparentsFragmentNodes() throws {
        let value = try swiftSoupEvaluation(
            "<p>alpha</p>", suffix: """
            try document.select("p").after("\\n\\n")
            try document.text()
            """)
        #expect(value.stringValue == "alpha")
    }

    /// IceCubes' `HTMLString.init(from:)` sanitizes parsed markup through a
    /// text-only whitelist before assigning `asRawText`. SwiftSoup's native
    /// CleanerTest pins this same contract: discarded elements retain their
    /// descendant text nodes.
    @Test func swiftSoupTextOnlyCleanerRetainsDescendantText() throws {
        let value = try swiftSoupEvaluation(
            "<p>Hello <strong>there</strong> friend</p>", suffix: """
            try SwiftSoup.clean(
                try document.html(), "", Whitelist.none(),
                OutputSettings().prettyPrint(pretty: false))
            """)
        #expect(value.unwrappedOptionalOrSelf?.stringValue?
            .contains("Hello there friend") == true)
    }

    /// IceCubes' `HTMLString.init(from:)` performs DOM edits before its
    /// text-only clean. Models also contributes a later top-level `Tag`; the
    /// complete SwiftSoup pipeline must retain its own same-named nominal.
    @Test func swiftSoupRecordedStatusPipelineRetainsText() throws {
        let value = try swiftSoupEvaluation(
            "<p>⭕Des familles ont été prises dans des nuages de gaz "
                + "lacrymogènes lancés par la police lors d’un tournoi de foot.</p>",
            additionalSource: """
            // swift-interpreter-source-module Models
            struct Tag {
                let marker: String
            }
            // swift-interpreter-source-module-end
            """,
            suffix: """
            document.outputSettings(
                OutputSettings().prettyPrint(pretty: false))
            try document.select("p.quote-inline").remove()
            try document.select("br").after("\\n")
            try document.select("p").after("\\n\\n")
            let html = try document.html()
            let text = try SwiftSoup.clean(
                html, "", Whitelist.none(),
                OutputSettings().prettyPrint(pretty: false)) ?? ""
            (try? Entities.unescape(text)) ?? text
            """)
        #expect(value.stringValue?
            .contains("⭕Des familles ont été prises") == true)
    }

    private func swiftSoupText(_ html: String) throws -> String? {
        try swiftSoupEvaluation(
            html, suffix: "try document.text()\n").stringValue
    }

    private func swiftSoupEvaluation(
        _ html: String,
        additionalSource: String = "",
        additionalSourceModule: String? = nil,
        suffix: String,
        suffixModule: String? = nil
    ) throws -> RuntimeValue {
        let root = FileManager.default.currentDirectoryPath
        let sourceRoot = root + "/.build/checkouts/SwiftSoup/Sources"
        let files = ProjectMaterial.swiftFiles(under: sourceRoot)
        guard !files.isEmpty else {
            throw RuntimeError(message:
                "SwiftSoup fixture sources are missing from \(sourceRoot)")
        }
        let projectedAdditional = additionalSourceModule.map {
            ProjectMaterial.mergedSource(
                source: additionalSource, moduleName: $0)
        } ?? additionalSource
        let projectedSuffix = suffixModule.map {
            ProjectMaterial.mergedSource(source: suffix, moduleName: $0)
        } ?? suffix
        let source = ProjectMaterial.mergedSource(
            files: files,
            sourceModules: Dictionary(uniqueKeysWithValues: files.map {
                ($0, "SwiftSoup")
            })) + "\n\n" + projectedAdditional
            + "\n\n// swift-interpreter-module SwiftSoup\n"
            + "let document = try SwiftSoup.parse(\(String(reflecting: html)))\n"
            + projectedSuffix

        return try Interpreter(registry: TraceRegistry()).run(source: source)
    }

}
