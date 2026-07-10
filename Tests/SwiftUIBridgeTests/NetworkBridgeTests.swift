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

/// The probe evaluates the app's DECLARED composition root — wrappers and
/// their environment seeding run for real.
@Suite struct DeclaredRootProbeTests {
    @Test func appSceneExpressionEvaluatesWithWrapper() throws {
        let source = """
        final class Catalog: ObservableObject {
            @Published var featured = "Featured: Dune"
        }

        let catalog = Catalog()

        struct Provider<Content: View>: View {
            let catalog: Catalog
            @ViewBuilder var content: () -> Content

            var body: some View {
                content()
                    .environmentObject(catalog)
            }
        }

        struct Shelf: View {
            @EnvironmentObject var catalog: Catalog

            var body: some View {
                Text(catalog.featured)
            }
        }

        @main
        struct ShopApp: App {
            var body: some Scene {
                WindowGroup {
                    Provider(catalog: catalog) {
                        Shelf()
                    }
                }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("Featured: Dune"),
                "the wrapper's environment seeding should reach the child, got \(strings)")
    }
}

/// Fresh-store doctrine v2 (M3): the model context backs a LIVE per-run
/// store — inserted models are fetchable within the run, deletes remove,
/// and separate interpreters never share state.
@Suite struct LiveModelStoreTests {
    @Test func insertFetchDeleteRoundTrip() throws {
        let source = """
        struct Note {
            var title = ""
        }

        struct ContentView: View {
            @Environment(\\.modelContext) private var context
            @State private var summary = "pending"

            var body: some View {
                Text("result \\(summary)")
                    .onAppear {
                        let before = context.fetchCount(FetchDescriptor<Note>())
                        context.insert(Note(title: "First"))
                        context.insert(Note(title: "Second"))
                        let notes = context.fetch(FetchDescriptor<Note>())
                        context.delete(notes[0])
                        let final = context.fetchCount(FetchDescriptor<Note>())
                        summary = "\\(before)-\\(notes.count)-\\(final)"
                    }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("result 0-2-1"), "insert→fetch→delete should round-trip, got \(strings)")
    }

    @Test func separateRunsStartEmpty() throws {
        let source = """
        struct Entry {
            var name = "x"
        }

        struct ContentView: View {
            @Environment(\\.modelContext) private var context
            @State private var count = -1

            var body: some View {
                Text("count \\(count)")
                    .onAppear {
                        context.insert(Entry())
                        count = context.fetchCount(FetchDescriptor<Entry>())
                    }
            }
        }
        """
        let first = try LiveCheckSupport.renderedStrings(source: source)
        let second = try LiveCheckSupport.renderedStrings(source: source)
        #expect(first == second, "runs must be deterministic: \(first) vs \(second)")
        #expect(first.contains("count 1"))
    }
}

/// The interaction rung × live store (M3): tapping Add inserts into the
/// live model store, and the re-rendered tree shows the new row.
@Suite struct InteractionRungTests {
    private static let todoSource = """
    struct Note {
        var title = ""
    }

    struct ContentView: View {
        @Environment(\\.modelContext) private var context
        @State private var tick = 0

        var body: some View {
            let notes = context.fetch(FetchDescriptor<Note>())
            return VStack {
                Button("Add") {
                    context.insert(Note(title: "Bought milk"))
                    tick += 1
                }
                ForEach(0..<notes.count) { index in
                    Text(notes[index].title)
                }
            }
        }
    }
    """

    @Test func addButtonInsertsVisibleRow() throws {
        let before = try LiveCheckSupport.renderedStrings(source: Self.todoSource)
        #expect(!before.contains("Bought milk"))
        let after = try LiveCheckSupport.renderedStrings(source: Self.todoSource, afterActions: 1)
        #expect(after.contains("Bought milk"),
                "the tapped insert should render as a row, got \(after)")
    }

    @Test func twoTapsTwoRows() throws {
        let after = try LiveCheckSupport.renderedStrings(source: Self.todoSource, afterActions: 2)
        #expect(after.filter { $0 == "Bought milk" }.count >= 2)
    }
}
