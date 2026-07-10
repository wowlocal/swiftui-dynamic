import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The IceCubes client genre: `get<Entity: Decodable>(…) -> Entity` must
/// thread the CALL-SITE annotation through nested generic calls into
/// `decoder.decode(Entity.self, from:)`.
@Suite struct GenericDecodeTests {
    private static func withFixture(_ json: String, _ run: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("generic-decode-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try json.write(toFile: directory + "/payload.json", atomically: true, encoding: .utf8)
        try run(directory)
    }

    @Test func annotationThreadsThroughNestedGenericCalls() throws {
        try Self.withFixture(#"[{"id": "1", "content": "hi"}, {"id": "2", "content": "yo"}]"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Status: Decodable {
                let id: String
                let content: String
            }
            struct Client {
                let decoder = JSONDecoder()
                func get<Entity: Decodable>() throws -> Entity {
                    try makeEntityRequest()
                }
                func makeEntityRequest<Entity: Decodable>() throws -> Entity {
                    try decoder.decode(Entity.self, from: __fixtureData("payload"))
                }
            }
            let client = Client()
            let statuses: [Status] = try client.get()
            statuses.map { $0.content }.joined(separator: ",")
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "hi,yo")
        }
    }

    @Test func propertyAssignmentAnnotationBinds() throws {
        // The TimelineViewModel genre: `statuses = try await client.get()` —
        // the TARGET property's declared type is the call-site annotation.
        try Self.withFixture(#"[{"id": "1", "content": "hi"}, {"id": "2", "content": "yo"}]"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Status: Decodable {
                let id: String
                let content: String
            }
            struct Client {
                let decoder = JSONDecoder()
                func get<Entity: Decodable>() throws -> Entity {
                    try decoder.decode(Entity.self, from: __fixtureData("payload"))
                }
            }
            class Model {
                var statuses: [Status] = []
                let client = Client()
                func fetch() throws {
                    statuses = try client.get()
                }
            }
            let model = Model()
            try model.fetch()
            model.statuses.map { $0.content }.joined(separator: ",")
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "hi,yo")
        }
    }

    @Test func singleObjectAnnotationBinds() throws {
        try Self.withFixture(#"{"id": "7", "content": "solo"}"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Status: Decodable {
                let id: String
                let content: String
            }
            struct Client {
                let decoder = JSONDecoder()
                func get<Entity: Decodable>() throws -> Entity {
                    try decoder.decode(Entity.self, from: __fixtureData("payload"))
                }
            }
            let client = Client()
            let status: Status = try client.get()
            status.content
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "solo")
        }
    }

    @Test func arrayReturnTypeBindsElement() throws {
        try Self.withFixture(#"[{"id": "3", "content": "el"}]"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Status: Decodable {
                let id: String
                let content: String
            }
            struct Client {
                let decoder = JSONDecoder()
                func list<Entity: Decodable>() throws -> [Entity] {
                    try decoder.decode([Entity].self, from: __fixtureData("payload"))
                }
            }
            let client = Client()
            let statuses: [Status] = try client.list()
            statuses[0].content
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "el")
        }
    }
}

/// Custom `init(from: Decoder)` runs against Decoder stubs (iteration 193):
/// scalar JSON through singleValueContainer (IceCubes' HTMLString decodes
/// from a plain string), object JSON through a keyed container with
/// snake_case fallback and decodeIfPresent — the type computes properties
/// its CodingKeys never mention (Account.cachedDisplayName).
@Suite struct CustomDecoderInitTests {
    @Test func scalarAndKeyedCustomInitsDecode() throws {
        let directory = NSTemporaryDirectory() + "custom-decode-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let json = #"""
        {"display_name": "Sun Dog", "username": "sundogplanets", "note": "<p>hello</p>"}
        """#
        try Data(json.utf8).write(to: URL(fileURLWithPath: directory + "/account.json"))
        NetworkBridge.policy = .replay(fixturesDirectory: directory)
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        struct HTMLString: Codable {
            var htmlValue = ""

            init(stringValue: String) {
                htmlValue = stringValue
            }

            init(from decoder: Decoder) {
                do {
                    let container = try decoder.singleValueContainer()
                    htmlValue = try container.decode(String.self)
                } catch {
                    htmlValue = ""
                }
            }
        }

        struct Account: Codable {
            let username: String
            let displayName: String?
            let note: HTMLString
            let cachedDisplayName: HTMLString

            enum CodingKeys: CodingKey {
                case username, displayName, note
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                username = try container.decode(String.self, forKey: .username)
                displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                note = try container.decode(HTMLString.self, forKey: .note)
                if let displayName, !displayName.isEmpty {
                    cachedDisplayName = .init(stringValue: displayName)
                } else {
                    cachedDisplayName = .init(stringValue: "@\\(username)")
                }
            }
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let account = try decoder.decode(Account.self, from: __fixtureData("account"))
        (account.username, account.cachedDisplayName.htmlValue, account.note.htmlValue)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].stringValue == "sundogplanets")
        #expect(tuple.values[1].stringValue == "Sun Dog")
        #expect(tuple.values[2].stringValue == "<p>hello</p>")
    }
}

/// Module-qualified extensions and shadowed stdlib statics (iteration 193):
/// `extension Models.Visibility` merges into the declared bare enum, and
/// `Duration.seconds(3)` reached through an app enum SHADOWING the stdlib
/// name reads as the typed clock marker (3.0 in arithmetic).
@Suite struct ModuleQualifiedExtensionTests {
    @Test func qualifiedExtensionAndShadowedDurationResolve() throws {
        let source = """
        enum Visibility: String, Codable {
            case pub = "public"
            case unlisted
        }

        extension Models.Visibility {
            var iconName: String {
                switch self {
                case .pub: "globe.americas"
                case .unlisted: "lock.open"
                }
            }
        }

        enum Duration: Int, CaseIterable {
            case instant = 0
            case fiveMinutes = 300
        }

        let visibility = Visibility.pub
        let pause = Swift.Duration.seconds(3) + Duration.seconds(2)
        (visibility.iconName, pause)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].stringValue == "globe.americas")
        #expect(tuple.values[1].doubleValue == 5.0)
    }
}

/// The APIService genre (iteration 198, movieswiftui): a generic
/// `GET<T: Codable>` whose T binds from the CALLER's typed completion
/// closure, decoded inside a nested dataTask completion — including the
/// callee's OWN generic struct (`PaginatedResponse<T>.results: [T]`).
@Suite struct CompletionClosureGenericTests {
    @Test func genericBindsFromTypedCompletionClosure() throws {
        let directory = NSTemporaryDirectory() + "flux-decode-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let json = #"{"page": 1, "total_results": 2, "results": [{"id": 1, "title": "Dune"}, {"id": 2, "title": "Arrival"}]}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: directory + "/3_movie_popular.json"))
        NetworkBridge.policy = .replay(fixturesDirectory: directory)
        defer { NetworkBridge.policy = .absorbed }
        let source = """
        struct Movie: Codable {
            let id: Int
            let title: String
        }

        struct PaginatedResponse<T: Codable>: Codable {
            let page: Int?
            let totalResults: Int?
            let results: [T]
        }

        enum APIError: Error {
            case noResponse
            case jsonDecodingError(error: Error)
        }

        final class APIService {
            static let shared = APIService()
            let decoder = JSONDecoder()

            init() {
                decoder.keyDecodingStrategy = .convertFromSnakeCase
            }

            func GET<T: Codable>(path: String,
                                 completionHandler: @escaping (Result<T, APIError>) -> Void) {
                let url = URL(string: "https://api.themoviedb.org" + path)!
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                    guard let data = data else {
                        completionHandler(.failure(.noResponse))
                        return
                    }
                    do {
                        let object = try self.decoder.decode(T.self, from: data)
                        completionHandler(.success(object))
                    } catch {
                        completionHandler(.failure(.jsonDecodingError(error: error)))
                    }
                }
                task.resume()
            }
        }

        var titles: [String] = []
        APIService.shared.GET(path: "/3/movie/popular") {
            (result: Result<PaginatedResponse<Movie>, APIError>) in
            switch result {
            case let .success(response):
                titles = response.results.map { $0.title }
            case .failure:
                break
            }
        }
        titles.joined(separator: "|")
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "Dune|Arrival", "got \(result.stringified)")
    }
}

@Suite struct DictMergeOperatorTests {
    @Test func customDictPlusEqualsMerges() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
struct Movie: Codable { let id: Int; let title: String }
func +=(lhs: inout [Int: Movie], rhs: [Movie]) {
    for movie in rhs {
        lhs[movie.id] = movie
    }
}
struct MoviesState {
    var movies: [Int: Movie] = [:]
}
var state = MoviesState()
state.movies += [Movie(id: 5, title: "Dune"), Movie(id: 9, title: "Arrival")]
(state.movies.count, state.movies[5]?.title ?? "missing")
""")
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 2)
        #expect(tuple.values[1].stringValue == "Dune")
    }
}

@Suite struct FluxShimTests {
    @Test func shimStoreDispatchReduces() throws {
        let shim = LibraryShims.shims(importedIn: ["SwiftUIFlux"], mergedSource: "")
        let source = """
        struct CounterState: FluxState {
            var count = 0
        }

        struct Increment: Action {
            let amount: Int
        }

        struct FetchThenIncrement: AsyncAction {
            func execute(state: FluxState?, dispatch: @escaping DispatchFunction) {
                dispatch(Increment(amount: 2))
            }
        }

        func counterReducer(state: CounterState, action: Action) -> CounterState {
            var state = state
            switch action {
            case let action as Increment:
                state.count += action.amount
            default:
                break
            }
            return state
        }

        let store = Store<CounterState>(reducer: counterReducer, state: CounterState())
        store.dispatch(action: Increment(amount: 1))
        store.dispatch(action: FetchThenIncrement())
        store.state.count
        """ + shim
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.intValue == 3, "got \(result.stringified)")
    }
}

@Suite struct ViewModifierBodyTests {
    @Test func customModifierRunsItsBody() throws {
        let source = """
        struct TitleFont: ViewModifier {
            let size: CGFloat

            func body(content: Content) -> some View {
                content.font(.system(size: size, weight: .bold, design: .rounded))
            }
        }

        extension View {
            func titleStyle() -> some View {
                self.modifier(TitleFont(size: 16))
            }
        }

        struct AppUserDefaults {
            @UserDefault("original_title", defaultValue: false)
            static var alwaysOriginalTitle: Bool
        }

        @propertyWrapper
        struct UserDefault<T> {
            let key: String
            let defaultValue: T

            init(_ key: String, defaultValue: T) {
                self.key = key
                self.defaultValue = defaultValue
            }

            var wrappedValue: T {
                get {
                    return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
                }
                set {
                    UserDefaults.standard.set(newValue, forKey: key)
                }
            }
        }

        struct ContentView: View {
            let title = "Dune Part Three"

            var userTitle: String {
                AppUserDefaults.alwaysOriginalTitle ? "DUNE III" : title
            }

            var body: some View {
                Text(userTitle)
                    .titleStyle()
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("Dune Part Three"),
                "the modifier body must pass content through, got \(strings)")
    }
}

@Suite struct ModifiedContentTests {
    @Test func explicitModifiedContentApplies() throws {
        let source = """
        struct Badge: ViewModifier {
            func body(content: Content) -> some View {
                content.padding()
            }
        }

        extension View {
            func badged() -> some View {
                return ModifiedContent(content: self, modifier: Badge())
            }
        }

        struct ContentView: View {
            var body: some View {
                Text("badge title").badged()
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("badge title"),
                "ModifiedContent(content:modifier:) runs the modifier body, got \(strings)")
    }
}

/// The `.modifier(m)` MEMBER spelling (iteration 199): interpreted
/// ViewModifier bodies run with the modifier's OWN environment injected —
/// custom keys read their declared @Entry defaults, absorbed nils in
/// arithmetic read fresh zero, and nested `.some/.none` payload patterns
/// match native optionals (the isowords AdaptivePadding switch).
@Suite struct ModifierMemberSpellingTests {
    @Test func modifierMemberRunsBodyWithEnvironment() throws {
        let source = """
        extension EnvironmentValues {
            @Entry var inferredPadding: CGFloat = 6
        }

        struct PaddedTitle: ViewModifier {
            @Environment(\\.inferredPadding) private var inferredPadding

            func body(content: Content) -> some View {
                let total = inferredPadding + 2
                return content.padding(total)
            }
        }

        struct ContentView: View {
            var body: some View {
                Text("member spelling").modifier(PaddedTitle())
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("member spelling"),
                "the modifier body must run and pass content through, got \(strings)")
    }

    @Test func nestedOptionalPayloadPatterns() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        enum Configuration {
            case edgeInsets(String)
            case edges(String, CGFloat?)
        }

        func describe(_ configuration: Configuration) -> String {
            switch configuration {
            case let .edgeInsets(insets):
                return "insets " + insets
            case let .edges(edges, .some(length)):
                return "edges \\(edges) length \\(length)"
            case let .edges(edges, .none):
                return "edges \\(edges) default"
            }
        }

        (describe(.edges("horizontal", 4)),
         describe(.edges("vertical", nil)),
         describe(.edgeInsets("custom")))
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].stringValue?.hasPrefix("edges horizontal length 4") == true)
        #expect(tuple.values[1].stringValue == "edges vertical default")
        #expect(tuple.values[2].stringValue == "insets custom")
    }
}

@Suite struct CastFalsePositiveTests {
    @Test func interpretedInstanceCastsCheckIdentity() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        protocol Action {}

        struct FetchList: Action {
            let page: Int
        }

        struct DidFetch: Action {
            let items: [String]
        }

        class ParentModel {}
        class ChildModel: ParentModel {}

        func classify(_ action: Action) -> String {
            if let didFetch = action as? DidFetch {
                return "did-fetch \\(didFetch.items.count)"
            }
            if action as? FetchList != nil {
                return "fetch-list"
            }
            return "other"
        }

        let child: ParentModel = ChildModel()
        (classify(FetchList(page: 1)),
         classify(DidFetch(items: ["a"])),
         child as? ChildModel != nil,
         child as? ParentModel != nil)
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].stringValue == "fetch-list")
        #expect(tuple.values[1].stringValue == "did-fetch 1")
        #expect(tuple.values[2].boolValue == true, "downcast to the real dynamic type holds")
        #expect(tuple.values[3].boolValue == true, "upcast to the superclass holds")
    }
}

/// @Query reads the LIVE model store (iteration 200, M3): what the UI
/// inserts through the model context, its queries show on the next
/// render — the todo-app loop closes end to end.
@Suite struct QueryLiveStoreTests {
    @Test func queryReflectsContextInserts() throws {
        let source = """
        struct Note {
            var title = ""
        }

        struct ContentView: View {
            @Environment(\\.modelContext) private var context
            @Query private var notes: [Note]

            var body: some View {
                VStack {
                    Button("Add") {
                        context.insert(Note(title: "Bought milk"))
                    }
                    ForEach(0..<notes.count) { index in
                        Text(notes[index].title)
                    }
                    Text("count \\(notes.count)")
                }
            }
        }
        """
        let before = try LiveCheckSupport.renderedStrings(source: source)
        #expect(before.contains("count 0"), "fresh store starts empty, got \(before)")
        let after = try LiveCheckSupport.renderedStrings(source: source, afterActions: 2)
        #expect(after.contains("Bought milk"), "inserted rows render through @Query, got \(after)")
        #expect(after.contains("count 2"), "two taps, two rows, got \(after)")
    }
}

/// clean-architecture-swiftui's Loadable genre (iteration 201, TestCheck):
/// NSLocalizedString returns its key (no bundle tables headlessly), and a
/// computed localizedDescription on an interpreted Error wins over the
/// host Error default.
@Suite struct LocalizedErrorDescriptionTests {
    @Test func computedLocalizedDescriptionResolves() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        struct ValueIsMissingError: Error {
            var localizedDescription: String {
                NSLocalizedString("Data is missing", comment: "")
            }
        }

        ValueIsMissingError().localizedDescription
        """)
        #expect(result.stringValue == "Data is missing", "got \(result.stringified)")
    }
}

/// `String(format:)` varargs must MATCH their directives: `%@` dereferences
/// an OBJECT pointer, so an Int riding under it was a SIGSEGV — the exact
/// shape NSLocalizedString unlocked (`String(format: NSLocalizedString(
/// "… %@ …"), count)`).
@Suite struct FormatDirectiveTests {
    @Test func objectDirectivesWrapScalars() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        let count = 42
        let name = "shelf"
        (String(format: NSLocalizedString("Showing %@ items", comment: ""), count),
         String(format: "%@ on %@", name, count),
         String(format: "%d of %.1f", count, 99.5),
         String(format: "100%% of %@", name))
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].stringValue == "Showing 42 items")
        #expect(tuple.values[1].stringValue == "shelf on 42")
        #expect(tuple.values[2].stringValue == "42 of 99.5")
        #expect(tuple.values[3].stringValue == "100% of shelf")
    }
}
