import Testing
@testable import SwiftInterpreter

@Suite struct DictEnumeratedTests {
    @Test func dictionaryEnumeratedYieldsKeyValuePairs() throws {
        let source = """
        let params = ["page": "1", "region": "US"]
        var out: [String] = []
        for (_, value) in params.enumerated() {
            out.append(value.key + "=" + value.value)
        }
        out.sorted().joined(separator: "&")
        """
        let result = try Interpreter().run(source: source)
        #expect(result.stringValue == "page=1&region=US")
    }

    @Test func dictionaryCollectionMembers() throws {
        // Native Dictionary Collection conformance: contains(where:)/filter/
        // compactMap/map over (key:, value:) elements — the MovieSwiftUI
        // ListImage genre (customLists.contains(where:) per rendered poster).
        let source = """
        struct CustomList {
            let name: String
            let movies: [Int]
        }
        let lists = [1: CustomList(name: "faves", movies: [7, 9]), 2: CustomList(name: "later", movies: [3])]
        let hasSeven = lists.contains(where: { $0.value.movies.contains(7) })
        let hasFifty = lists.contains(where: { $0.value.movies.contains(50) })
        let faves = lists.filter { $0.value.name == "faves" }
        let names = lists.compactMap { $0.value.movies.count > 1 ? $0.value.name : nil }
        "\\(hasSeven) \\(hasFifty) \\(faves.count) \\(names.joined(separator: ","))"
        """
        let result = try Interpreter().run(source: source)
        #expect(result.stringValue == "true false 1 faves")
    }

    @Test func dictionarySortedByPredicate() throws {
        let source = """
        let scores = ["b": 2, "a": 1, "c": 3]
        let ordered = scores.sorted { $0.key < $1.key }
        ordered.map { "\\($0.key)=\\($0.value)" }.joined(separator: ",")
        """
        let result = try Interpreter().run(source: source)
        #expect(result.stringValue == "a=1,b=2,c=3")
    }
}
