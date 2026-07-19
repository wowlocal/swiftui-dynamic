import Testing
@testable import SwiftInterpreter

@MainActor
@Suite("Optional cast semantics")
struct OptionalCastTests {
    @Test func conditionalCastChecksWrappedRuntimeType() throws {
        let source = """
        class Node {}
        final class Element: Node {}
        final class TextNode: Node {
            func wholeTextSlice() -> Int { 1 }
        }

        let children: [Node] = [Element()]
        var result = 0
        if let textNode = children.first as? TextNode {
            result = textNode.wholeTextSlice()
        } else {
            result = 42
        }
        result
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 42)
    }
}
