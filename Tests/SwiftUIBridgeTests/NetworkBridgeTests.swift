import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The network bridge in REPLAY mode: URLSession serves recorded real API
/// bytes, JSONDecoder structurally decodes into interpreted types. Fixtures
/// under Fixtures/ are actual responses captured from the live services —
/// the network's native baseline.
@Suite struct NetworkBridgeTests {
    private static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures").path

    @Test func decodesMastodonTimelineFixture() throws {
        NetworkBridge.policy = .replay(fixturesDirectory: Self.fixturesRoot + "/mastodon-public-timeline")
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        struct Account: Codable {
            let username: String
            let displayName: String?
        }

        struct Status: Codable {
            let id: String
            let content: String
            let createdAt: Date
            let account: Account
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let statuses = try decoder.decode([Status].self, from: __fixtureData("api_v1_timelines_public"))
        (statuses.count, statuses[0].account.username, statuses[0].id)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 20)
        #expect((tuple.values[1].stringValue ?? "").isEmpty == false)
        #expect((tuple.values[2].stringValue ?? "").isEmpty == false)
    }

    @Test func urlSessionReplayServesFixtureBytes() throws {
        NetworkBridge.policy = .replay(fixturesDirectory: Self.fixturesRoot + "/tmdb-popular")
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        let url = URL(string: "https://api.themoviedb.org/3/movie/popular?api_key=x&page=1")!
        let (data, response) = try await URLSession.shared.data(from: url)
        (response.statusCode, data.count)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 200)
        #expect((tuple.values[1].intValue ?? 0) > 1000)
    }

    @Test func replayMissThrowsHonestly() throws {
        NetworkBridge.policy = .replay(fixturesDirectory: Self.fixturesRoot + "/tmdb-popular")
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        let url = URL(string: "https://example.com/api/unrecorded")!
        let (data, _) = try await URLSession.shared.data(from: url)
        data
        """
        #expect(throws: (any Error).self) {
            try Interpreter(registry: ViewRegistry()).run(source: source)
        }
    }

    @Test func codingKeysAndRawEnumsDecode() throws {
        let directory = NSTemporaryDirectory() + "livecheck-tests-\(ProcessInfo.processInfo.processIdentifier)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let json = #"{"full_name": "Ada Lovelace", "kind": "vip", "score": 9.5, "tags": ["math", "code"]}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: directory + "/person.json"))
        NetworkBridge.policy = .replay(fixturesDirectory: directory)
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        enum Kind: String, Codable {
            case vip
            case basic
        }

        struct Person: Codable {
            let name: String
            let kind: Kind
            let score: Double
            let tags: [String]
            let nickname: String?

            enum CodingKeys: String, CodingKey {
                case name = "full_name"
                case kind
                case score
                case tags
            }
        }

        let person = try JSONDecoder().decode(Person.self, from: __fixtureData("person"))
        (person.name, person.kind == .vip, person.score, person.tags.count, person.nickname == nil)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].stringValue == "Ada Lovelace")
        #expect(tuple.values[1].boolValue == true)
        #expect(tuple.values[2].doubleValue == 9.5)
        #expect(tuple.values[3].intValue == 2)
        #expect(tuple.values[4].boolValue == true)
    }
}

/// The M2 async-fetch pass: LiveCheck's probe fires retained `.task`/
/// `.onAppear` closures and re-renders, so fetched data reaches the tree.
@Suite struct AsyncFetchProbeTests {
    @Test func taskFetchedDataReachesTheTree() throws {
        NetworkBridge.policy = .replay(
            fixturesDirectory: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/tmdb-popular").path)
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        struct Movie: Codable {
            let id: Int
            let title: String
        }

        struct MovieResponse: Codable {
            let results: [Movie]
        }

        final class Library: ObservableObject {
            @Published var titles: [String] = []

            func load() {
                let url = URL(string: "https://api.themoviedb.org/3/movie/popular?api_key=x")!
                let (data, _) = try! URLSession.shared.data(from: url)
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let response = try! decoder.decode(MovieResponse.self, from: data)
                titles = response.results.map { $0.title }
            }
        }

        struct ContentView: View {
            @StateObject var library = Library()

            var body: some View {
                List {
                    ForEach(library.titles, id: \\.self) { title in
                        Text(title)
                    }
                }
                .task {
                    library.load()
                }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.count >= 10, "fetched titles should reach the tree, got \(strings.count) strings")
    }

    @Test func onAppearStateChangeReachesTheTree() throws {
        let source = """
        struct ContentView: View {
            @State private var label = "before"

            var body: some View {
                Text(label)
                    .onAppear {
                        label = "after"
                    }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("after"))
        #expect(!strings.contains("before") || strings.contains("after"))
    }
}
