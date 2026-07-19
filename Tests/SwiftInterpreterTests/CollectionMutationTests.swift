import Testing
@testable import SwiftInterpreter

@Suite struct CollectionMutationTests {
    /// The active stdlib declares this RangeReplaceableCollection default in
    /// terms of replaceSubrange; Array executes the same half-open mutation.
    @Test func generatedRangeRemovalMutatesArrayStorage() throws {
        let source = """
        var values = [0, 1, 2, 3]
        values.removeSubrange(1..<3)
        values.count * 10 + values[1]
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 23)
    }
}
