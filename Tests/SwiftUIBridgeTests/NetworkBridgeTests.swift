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

    @Test func generatedWritableFoundationReferencePropertyRoundTrips() throws {
        #expect(
            GeneratedFoundationReferenceProperties.declarationsByKey[
                "URLSession.sessionDescription"]
                == "var URLSession.sessionDescription: String? { get set }")
        let box = URLSessionBox(generatedReferenceTypeName: "URLSession")
        #expect(box.generatedReferenceTypeName == "URLSession")
        #expect(
            GeneratedReferencePropertySupport.property(
                "sessionDescription", on: box) != nil)
        #expect(
            ViewRegistry().hostProperty(
                named: "sessionDescription", on: box) != nil)
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
            let session = URLSession(
                configuration: URLSessionConfiguration.default)
            session.sessionDescription = "Nuke URLSession"
            session.sessionDescription
            """)
        #expect(
            result.unwrappedOptionalOrSelf?.stringValue
                == "Nuke URLSession")
    }

    /// Nuke configures inherited URLSessionTask properties before resume.
    /// The writable surface comes from Foundation metadata even though the
    /// replay task itself is a handwritten reference box.
    @Test func generatedWritableTaskPropertyPreservesResume() throws {
        NetworkBridge.policy = .replay(fixturesDirectory: NSTemporaryDirectory())
        NetworkBridge.requestLog = []
        defer { NetworkBridge.policy = .absorbed }
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
            let task = URLSession.shared.dataTask(
                with: URL(string: "https://example.com/generated-property")!
            ) { _, _, _ in }
            task.prefersIncrementalDelivery = true
            let configured = task.prefersIncrementalDelivery
            task.resume()
            configured
            """)
        #expect(result.boolValue == true)
        #expect(NetworkBridge.requestLog.contains { $0.contains("generated-property") })
    }

    /// IceCubes' Nuke 12.8 `ImageCache.init` derives its cost limit from this
    /// exact read-only SDK-property expression. A compiled native run returns
    /// the host's physical byte count divided by five; the interpreter must
    /// retain the `UInt64` payload rather than absorbing the property into an
    /// unknowable host member.
    @Test func generatedReadOnlyFoundationPropertyUsesNativePayload() throws {
        let expected = ProcessInfo.processInfo.physicalMemory / UInt64(5)
        let result = try Interpreter(registry: ViewRegistry()).run(
            source: """
            let ratio = 0.2
            ProcessInfo.processInfo.physicalMemory / UInt64(1 / ratio)
            """)
        #expect(result.stringified == String(expected))
    }

    /// Selecting a Foundation class for generated native dispatch must not
    /// bypass source extensions on that host type. This is the distilled
    /// AlDente corpus path; native arm64 returns `arm64` from the same bytes.
    @Test func generatedFoundationValueDispatchesSourceExtension() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
            import AppKit

            extension ProcessInfo {
                var machineHardwareName: String? {
                    var sysinfo = utsname()
                    let result = uname(&sysinfo)
                    guard result == EXIT_SUCCESS else { return nil }
                    let data = Data(
                        bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
                    guard let identifier = String(
                        bytes: data, encoding: .ascii) else { return nil }
                    return identifier.trimmingCharacters(
                        in: .controlCharacters)
                }
            }
            ProcessInfo.init().machineHardwareName
            """,
            lazyTopLevelGlobals: true)
        #expect(result.unwrappedOptionalOrSelf?.stringValue == "arm64")
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

    /// IceCubes' full client chain (iteration 190): an ACTOR builds the URL
    /// through URLComponents, wraps it in `URLRequest(url:)`, sets method +
    /// header, and calls `session.data(for: request)` — every link must
    /// stay real for the replay fixture to land.
    @Test func actorClientRequestChainLandsInReplay() throws {
        NetworkBridge.policy = .replay(fixturesDirectory: Self.fixturesRoot + "/mastodon-public-timeline")
        defer { NetworkBridge.policy = .absorbed }
        NetworkBridge.requestLog = []
        let source = """
        struct Account: Codable {
            let username: String
        }

        struct Status: Codable {
            let id: String
            let account: Account
        }

        protocol Endpoint {
            func path() -> String
            func queryItems() -> [URLQueryItem]?
        }

        enum Oauth: Endpoint {
            case authorize
            func path() -> String { "oauth/authorize" }
            func queryItems() -> [URLQueryItem]? { nil }
        }

        enum Trends: Endpoint {
            case tags
            case statuses(offset: Int?)

            func path() -> String {
                switch self {
                case .tags:
                    "trends/tags"
                case .statuses:
                    "trends/statuses"
                }
            }

            func queryItems() -> [URLQueryItem]? {
                switch self {
                case let .statuses(offset):
                    if let offset {
                        return [.init(name: "offset", value: String(offset))]
                    }
                    return nil
                default:
                    return nil
                }
            }
        }

        struct OauthToken: Codable {
            let accessToken: String
        }

        @Observable
        final class Client: Equatable, Identifiable, Sendable {
            static func == (lhs: Client, rhs: Client) -> Bool {
                lhs.server == rhs.server
            }

            enum Version: String, Sendable {
                case v1, v2
            }

            enum ClientError: Error {
                case unexpectedRequest
            }

            let server: String
            let version: Version
            private let urlSession: URLSession
            private let decoder = JSONDecoder()

            private let critical: OSAllocatedUnfairLock<Critical>
            private struct Critical: Sendable {
                var oauthToken: OauthToken?
                var connections: Set<String> = []
            }

            init(server: String, version: Version = .v1, oauthToken: OauthToken? = nil) {
                self.server = server
                self.version = version
                critical = .init(initialState: Critical(oauthToken: oauthToken, connections: [server]))
                urlSession = URLSession.shared
                decoder.keyDecodingStrategy = .convertFromSnakeCase
            }

            private func makeURL(
                scheme: String = "https", endpoint: Endpoint, forceVersion: Version? = nil
            ) throws -> URL {
                var components = URLComponents()
                components.scheme = scheme
                components.host = server
                if type(of: endpoint) == Oauth.self {
                    components.path += "/\\(endpoint.path())"
                } else {
                    components.path += "/api/\\(forceVersion?.rawValue ?? version.rawValue)/\\(endpoint.path())"
                }
                components.queryItems = endpoint.queryItems()
                guard let url = components.url else {
                    throw ClientError.unexpectedRequest
                }
                return url
            }

            private func makeURLRequest(url: URL, endpoint: Endpoint, httpMethod: String) -> URLRequest {
                var request = URLRequest(url: url)
                request.httpMethod = httpMethod
                if let oauthToken = critical.withLock({ $0.oauthToken }) {
                    request.setValue("Bearer \\(oauthToken.accessToken)", forHTTPHeaderField: "Authorization")
                }
                return request
            }

            func get<Entity: Decodable>(endpoint: Endpoint, forceVersion: Version? = nil) async throws
                -> Entity
            {
                try await makeEntityRequest(endpoint: endpoint, method: "GET", forceVersion: forceVersion)
            }

            private func makeEntityRequest<Entity: Decodable>(
                endpoint: Endpoint, method: String, forceVersion: Version? = nil
            ) async throws -> Entity {
                let url = try makeURL(endpoint: endpoint, forceVersion: forceVersion)
                let request = makeURLRequest(url: url, endpoint: endpoint, httpMethod: method)
                let (data, _) = try await urlSession.data(for: request)
                return try decoder.decode(Entity.self, from: data)
            }
        }

        protocol TimelineStatusFetching: Sendable {
            func fetchFirstPage(client: Client?) async throws -> [Status]
        }

        struct DefaultStatusFetcher: TimelineStatusFetching {
            func fetchFirstPage(client: Client?) async throws -> [Status] {
                guard let client else { throw Client.ClientError.unexpectedRequest }
                return try await client.get(endpoint: Trends.statuses(offset: nil))
            }
        }

        let fetcher: TimelineStatusFetching = DefaultStatusFetcher()
        let client = Client(server: "mastodon.social")
        let statuses = try await fetcher.fetchFirstPage(client: client)
        (statuses.count, statuses[0].account.username)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect((tuple.values[0].intValue ?? 0) >= 10,
                "fixture statuses should decode, got \(tuple.values[0].stringified); log: \(NetworkBridge.requestLog)")
        #expect((tuple.values[1].stringValue ?? "").isEmpty == false)
        #expect(NetworkBridge.requestLog.contains { $0.contains("trends/statuses") && $0.contains("hit") },
                "the request should land in the replay log, got \(NetworkBridge.requestLog)")
    }

    /// The IceCubes TRIGGER shape (iteration 190): `.onAppear` assigns a
    /// property whose didSet spawns `Task { await fetch() }` — the observer
    /// runs, the task body executes inline, and the request lands.
    @Test func didSetTaskFetchLandsRequest() async throws {
        NetworkBridge.policy = .replay(fixturesDirectory: Self.fixturesRoot + "/mastodon-public-timeline")
        defer { NetworkBridge.policy = .absorbed }
        NetworkBridge.requestLog = []
        let source = """
        struct Account: Codable {
            let username: String
        }

        struct Status: Codable {
            let id: String
            let account: Account
        }

        @Observable
        @MainActor
        final class TimelineVM {
            var client: String?
            var loadedCount = 0
            var timelineTask: Task<Void, Never>?
            var timeline: String = "unset" {
                didSet {
                    timelineTask?.cancel()
                    timelineTask = Task {
                        await fetchNewestStatuses()
                    }
                }
            }

            func fetchNewestStatuses() async {
                guard let client else { return }
                do {
                    let url = URL(string: "https://\\(client)/api/v1/trends/statuses")!
                    // URLRequest wraps as the registry's catch-all bag —
                    // under the TRACE registry too, data(for:) must find
                    // the url riding in the bag's config.
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let statuses = try decoder.decode([Status].self, from: data)
                    loadedCount = statuses.count
                } catch {}
            }
        }

        struct ContentView: View {
            @State private var viewModel = TimelineVM()

            var body: some View {
                Text("loaded \\(viewModel.loadedCount)")
                    .onAppear {
                        if viewModel.client == nil {
                            viewModel.client = "mastodon.social"
                        }
                        viewModel.timeline = "trending"
                    }
            }
        }
        """
        let render = try await LiveCheckSupport.render(source: source)
        #expect(render.networkRequests.contains { $0.contains("trends/statuses") },
                "didSet's Task should fetch, log: \(render.networkRequests)")
        #expect(render.strings.contains { $0.contains("loaded 20") },
                "fetched count should reach the tree, got \(render.strings)")
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

/// Fresh-state doctrine: an unknowable's `isEmpty` reads TRUE — the same
/// fresh collection iterates EMPTY in for-in and equals zero through
/// `count == 0`, so all three readings agree. IceCubes' cache guard
/// (`if let cached = await getCachedItems(), !cached.isEmpty`) must fall
/// to the NETWORK branch, exactly as on a fresh install.
@Suite struct FreshEmptinessTests {
    @Test func absorbedCacheGuardFallsToNetworkBranch() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                let cached = DiskCache.shared.items(for: "timeline")
                let branch: String
                if !cached.isEmpty {
                    branch = "cache"
                } else {
                    branch = "network"
                }
                var iterated = 0
                for _ in cached { iterated += 1 }
                if cached.isEmpty != true || iterated != 0 || cached.count != 0 {
                    fatalError("fresh readings disagree")
                }
                return Text(branch)
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        #expect(report.nodeCount >= 1)
    }
}

/// Observation's TYPED environment: `.environment(model)` seeds by symbol
/// name; `@Environment(Model.self) var model` reads the SAME instance (the
/// IceCubes client-injection shape).
@Suite struct TypedEnvironmentTests {
    @Test func typedEnvironmentModelReachesChild() async throws {
        let source = """
        @Observable
        final class MastodonClient {
            var server = "mastodon.social"
        }

        struct TimelineView: View {
            @Environment(MastodonClient.self) private var client

            var body: some View {
                Text("server: \\(client.server)")
            }
        }

        @main
        struct FeedApp: App {
            @State var client = MastodonClient()

            var body: some Scene {
                WindowGroup {
                    TimelineView()
                        .environment(client)
                }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("server: mastodon.social"),
                "the typed environment model should reach the child, got \(strings)")
    }
}

/// The M2 async-fetch pass: LiveCheck's probe fires retained `.task`/
/// `.onAppear` closures and re-renders, so fetched data reaches the tree.
@Suite struct AsyncFetchProbeTests {
    @Test func taskFetchedDataReachesTheTree() async throws {
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
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.count >= 10, "fetched titles should reach the tree, got \(strings.count) strings")
    }

    @Test func onAppearStateChangeReachesTheTree() async throws {
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
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("after"))
        #expect(!strings.contains("before") || strings.contains("after"))
    }
}

/// The probe evaluates the app's DECLARED composition root — wrappers and
/// their environment seeding run for real.
@Suite struct DeclaredRootProbeTests {
    @Test func appSceneExpressionEvaluatesWithWrapper() async throws {
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
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("Featured: Dune"),
                "the wrapper's environment seeding should reach the child, got \(strings)")
    }
}

/// Fresh-store doctrine v2 (M3): the model context backs a LIVE per-run
/// store — inserted models are fetchable within the run, deletes remove,
/// and separate interpreters never share state.
@Suite struct LiveModelStoreTests {
    @Test func insertFetchDeleteRoundTrip() async throws {
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
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("result 0-2-1"), "insert→fetch→delete should round-trip, got \(strings)")
    }

    @Test func separateRunsStartEmpty() async throws {
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
        let first = try await LiveCheckSupport.renderedStrings(source: source)
        let second = try await LiveCheckSupport.renderedStrings(source: source)
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

    @Test func addButtonInsertsVisibleRow() async throws {
        let before = try await LiveCheckSupport.renderedStrings(source: Self.todoSource)
        #expect(!before.contains("Bought milk"))
        let after = try await LiveCheckSupport.renderedStrings(source: Self.todoSource, afterActions: 1)
        #expect(after.contains("Bought milk"),
                "the tapped insert should render as a row, got \(after)")
    }

    @Test func twoTapsTwoRows() async throws {
        let after = try await LiveCheckSupport.renderedStrings(source: Self.todoSource, afterActions: 2)
        #expect(after.filter { $0 == "Bought milk" }.count >= 2)
    }
}

/// M4 App-shell env seeding: the scene expression evaluates with the APP
/// instance as self, so its @StateObject properties flow into
/// .environmentObject exactly as at launch (the IceCubes shape).
@Suite struct AppShellEnvSeedingTests {
    @Test func appStateObjectSeedsEnvironment() async throws {
        let source = """
        final class AccountsManager: ObservableObject {
            @Published var current = "alice@mstdn.social"
        }

        struct TimelineView: View {
            @EnvironmentObject var accounts: AccountsManager

            var body: some View {
                Text("signed in: \\(accounts.current)")
            }
        }

        @main
        struct FeedApp: App {
            @StateObject var accounts = AccountsManager()

            var body: some Scene {
                WindowGroup {
                    TimelineView()
                        .environmentObject(accounts)
                }
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("signed in: alice@mstdn.social"),
                "the App's @StateObject should seed the environment, got \(strings)")
    }
}
