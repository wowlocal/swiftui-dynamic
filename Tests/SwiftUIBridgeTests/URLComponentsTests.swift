import Testing
import SwiftInterpreter
import SwiftUIBridge

/// The client-genre `makeURL` idiom (IceCubes MastodonClient): components
/// built member-write by member-write must yield a REAL URL.
@Suite struct URLComponentsTests {
    @Test func makeURLIdiomBuildsRealURL() throws {
        let source = """
        func makeURL(server: String, path: String) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            components.host = server
            components.path += "/api/v1/\\(path)"
            components.queryItems = [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "local", value: nil)]
            return components.url
        }
        let url = makeURL(server: "mastodon.social", path: "timelines/public")
        url?.absoluteString ?? "NIL"
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "https://mastodon.social/api/v1/timelines/public?limit=20&local")
    }

    @Test func componentsFromStringRoundTrip() throws {
        let source = """
        var components = URLComponents(string: "https://example.com/a/b?x=1")!
        let host = components.host ?? "?"
        let query = components.query ?? "?"
        components.path = "/other"
        [host, query, components.url?.absoluteString ?? "NIL"].joined(separator: "|")
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "example.com|x=1|https://example.com/other?x=1")
    }

    @Test func queryItemsReadBack() throws {
        let source = """
        var components = URLComponents(string: "https://example.com/s?q=swift&page=2")!
        let items = components.queryItems ?? []
        items.map { "\\($0.name)=\\($0.value ?? "nil")" }.joined(separator: ",")
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "q=swift,page=2")
    }
}
