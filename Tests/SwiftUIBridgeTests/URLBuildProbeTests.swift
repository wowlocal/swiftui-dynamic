import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct URLBuildProbeTests {
    @Test func apiServiceURLBuildShape() throws {
        let source = """
        struct API {
            let baseURL = URL(string: "https://api.themoviedb.org/3")!
            func url() -> String {
                let queryURL = baseURL.appendingPathComponent("movie/popular")
                var components = URLComponents(url: queryURL, resolvingAgainstBaseURL: true)!
                components.queryItems = [URLQueryItem(name: "api_key", value: "k")]
                return components.url!.absoluteString
            }
        }
        API().url()
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        print("URL BUILD: \(result.stringValue ?? "NIL")")
        #expect(result.stringValue == "https://api.themoviedb.org/3/movie/popular?api_key=k")
        let traced = try Interpreter(registry: TraceRegistry()).run(source: source)
        print("URL BUILD TRACE: \(traced.stringValue ?? "NIL")")
        #expect(traced.stringValue == "https://api.themoviedb.org/3/movie/popular?api_key=k")
    }

    @Test func apiServiceDataTaskShape() throws {
        NetworkBridge.requestLog = []
        NetworkBridge.policy = .replay(fixturesDirectory: NSTemporaryDirectory())
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        struct API {
            let baseURL = URL(string: "https://api.themoviedb.org/3")!
            func fetch() {
                let queryURL = baseURL.appendingPathComponent("movie/popular")
                var components = URLComponents(url: queryURL, resolvingAgainstBaseURL: true)!
                components.queryItems = [URLQueryItem(name: "api_key", value: "k")]
                var request = URLRequest(url: components.url!)
                request.httpMethod = "GET"
                let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                    _ = data
                }
                task.resume()
            }
        }
        API().fetch()
        """
        _ = try Interpreter(registry: TraceRegistry()).run(source: source)
        print("REQUEST LOG: \(NetworkBridge.requestLog)")
        #expect(NetworkBridge.requestLog.first?.contains("/3/movie/popular") == true,
                "request path lost: \(NetworkBridge.requestLog)")
    }
}
