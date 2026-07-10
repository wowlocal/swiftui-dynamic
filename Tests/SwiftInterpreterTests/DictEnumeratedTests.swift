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
}
