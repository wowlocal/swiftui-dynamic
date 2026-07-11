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

/// LoadableTests.map distilled (iteration 202): generic enum map with
/// optional-map rethrows and conditional-conformance equality.
@Suite struct LoadableMapTests {
    @Test func loadableMapTransformsAndCompares() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        final class CancelBag {
            private let equalToAny: Bool

            init(equalToAny: Bool = false) {
                self.equalToAny = equalToAny
            }

            static var test: CancelBag { CancelBag(equalToAny: true) }

            func isEqual(to other: CancelBag) -> Bool {
                return other === self || other.equalToAny || self.equalToAny
            }
        }

        enum Loadable<T> {
            case notRequested
            case isLoading(last: T?, cancelBag: CancelBag)
            case loaded(T)
            case failed(Error)

            var value: T? {
                switch self {
                case let .loaded(value): return value
                case let .isLoading(last, _): return last
                default: return nil
                }
            }

            func map<V>(_ transform: (T) throws -> V) -> Loadable<V> {
                do {
                    switch self {
                    case .notRequested: return .notRequested
                    case let .failed(error): return .failed(error)
                    case let .isLoading(value, cancelBag):
                        return .isLoading(last: try value.map { try transform($0) },
                                          cancelBag: cancelBag)
                    case let .loaded(value):
                        return .loaded(try transform(value))
                    }
                } catch {
                    return .failed(error)
                }
            }
        }

        extension Loadable: Equatable where T: Equatable {
            static func == (lhs: Loadable<T>, rhs: Loadable<T>) -> Bool {
                switch (lhs, rhs) {
                case (.notRequested, .notRequested): return true
                case let (.isLoading(lhsV, lhsC), .isLoading(rhsV, rhsC)):
                    return lhsV == rhsV && lhsC.isEqual(to: rhsC)
                case let (.loaded(lhsV), .loaded(rhsV)): return lhsV == rhsV
                case let (.failed(lhsE), .failed(rhsE)):
                    return lhsE.localizedDescription == rhsE.localizedDescription
                default: return false
                }
            }
        }

        let error = NSError(domain: "test", code: 0,
                            userInfo: [NSLocalizedDescriptionKey: "Test error"])
        let values: [Loadable<Int>] = [
            .notRequested,
            .isLoading(last: nil, cancelBag: CancelBag()),
            .isLoading(last: 5, cancelBag: CancelBag()),
            .loaded(7),
            .failed(error)
        ]
        let expect: [Loadable<String>] = [
            .notRequested,
            .isLoading(last: nil, cancelBag: .test),
            .isLoading(last: "5", cancelBag: .test),
            .loaded("7"),
            .failed(error)
        ]
        let sut = values.map { value in
            value.map { "\\($0)" }
        }
        (sut[0] == expect[0], sut[1] == expect[1], sut[2] == expect[2],
         sut[3] == expect[3], sut[4] == expect[4], sut == expect)
        """)
        let tuple = try #require(result.tupleValue)
        for (index, value) in tuple.values.enumerated() {
            #expect(value.boolValue == true, "element \(index) mismatched: \(value.stringified)")
        }
    }
}

/// SE-0249 keypaths in DICTIONARY transform positions (iteration 204):
/// `dataSource.map(\.key)` over [Vehicle: [Event]] — the Basic-Car picker.
@Suite struct DictionaryKeyPathTransformTests {
    @Test func dictMapAcceptsKeyPaths() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        struct Vehicle: Hashable {
            let name: String
        }

        let dataSource: [Vehicle: [Int]] = [Vehicle(name: "Civic"): [1, 2]]
        let vehicles = dataSource.map(\\.key)
        let names = dataSource.compactMap(\\.key.name)
        (vehicles.count, vehicles[0].name, names[0])
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 1)
        #expect(tuple.values[1].stringValue == "Civic")
        #expect(tuple.values[2].stringValue == "Civic")
    }
}

/// Interpreted URLProtocol mocking (iteration 205, the RequestMocking
/// genre): a declared URLProtocol subclass whose canInit accepts a request
/// serves session.data through startLoading against a recording client —
/// JSONEncoder round-trips the mocked payload, HTTPURLResponse carries the
/// code, and mocked failures throw the app's own error type.
@Suite struct URLProtocolMockTests {
    @Test func mockedProtocolServesSessionData() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        struct Country: Codable, Equatable {
            let name: String
            let population: Int
        }

        final class MocksContainer {
            static var mocks: [(url: String, data: Data, code: Int)] = []
        }

        final class RequestMocking: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                MocksContainer.mocks.contains { request.url?.absoluteString == $0.url }
            }

            override func startLoading() {
                guard let mock = MocksContainer.mocks.first(where: {
                    request.url?.absoluteString == $0.url
                }), let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: mock.code,
                                               httpVersion: "HTTP/1.1", headerFields: nil) else {
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: mock.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = [Country(name: "Georgia", population: 3_700_000)]
        let data = try encoder.encode(payload)
        MocksContainer.mocks.append((url: "https://api.example.com/countries", data: data, code: 200))

        let url = URL(string: "https://api.example.com/countries")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (received, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let countries = try decoder.decode([Country].self, from: received)
        (countries.count, countries[0].name, countries[0].population, response.statusCode)
        """)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 1)
        #expect(tuple.values[1].stringValue == "Georgia")
        #expect(tuple.values[2].intValue == 3_700_000)
        #expect(tuple.values[3].intValue == 200)
    }
}

/// The ACHNBrowser boot chain (iteration 206): item-gated sheet content,
/// pre-@Entry EnvironmentKey defaults, optional views in builders, and the
/// synthesized-allCases collision with an argful static overload.
@Suite struct ACHNBootChainTests {
    @Test func itemSheetGatesAndEnvironmentKeyDefaults() throws {
        let source = """
        struct CurrentDateKey: EnvironmentKey {
            static let defaultValue = Date()
        }

        extension EnvironmentValues {
            var currentDate: Date {
                self[CurrentDateKey.self]
            }
        }

        enum Route: Identifiable {
            case detail(name: String)

            var id: String { "detail" }

            func makeSheetView() -> some View {
                Text("sheet content")
            }
        }

        enum Sort: String, CaseIterable {
            case name, buy

            static func allCases(for category: String) -> [Sort] {
                allCases.filter { $0 != .buy || category == "shop" }
            }
        }

        struct ContentView: View {
            @Environment(\\.currentDate) private var currentDate
            @State private var route: Route?
            let maybeExtra: String? = nil

            var body: some View {
                VStack {
                    Text("hour \\(Calendar.current.component(.hour, from: currentDate))")
                    Text("sorts \\(Sort.allCases(for: "museum").count)")
                    maybeExtra.map { Text($0) }
                }
                .sheet(item: $route) {
                    $0.makeSheetView()
                }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.hasPrefix("hour ") && !$0.contains("nil") },
                "EnvironmentKey defaultValue must resolve, got \(strings)")
        #expect(strings.contains("sorts 1"), "argful allCases dispatches; bare reads synthesized")
        #expect(!strings.contains("sheet content"), "nil-item sheets stay unpresented")
    }
}

/// The bundled-resource Combine genre (iteration 207): Result(catching:)
/// .publisher.decode → sink populates @Published; $published projections
/// deliver the CURRENT value synchronously in replay (the doctrine fork);
/// Bundle.module resolves committed resources.
@Suite struct BundledResourcePipelineTests {
    @Test func bundleResourceRidesPublisherIntoPublished() throws {
        NetworkBridge.policy = .replay(fixturesDirectory: NSTemporaryDirectory())
        defer { NetworkBridge.policy = .absorbed }
        let previousRoot = BundleBox.projectResourceRoot
        let root = NSTemporaryDirectory() + "bundle-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/Resources/json", withIntermediateDirectories: true)
        defer {
            BundleBox.projectResourceRoot = previousRoot
            try? FileManager.default.removeItem(atPath: root)
        }
        try #"{"total": 2, "results": [{"name": "Goldfish"}, {"name": "Anchovy"}]}"#
            .write(toFile: root + "/Resources/json/fish", atomically: true, encoding: .utf8)
        BundleBox.projectResourceRoot = root
        let source = """
        struct ItemRow: Codable {
            let name: String
        }

        struct FileResponse: Codable {
            let total: Int
            let results: [ItemRow]
        }

        final class Items: ObservableObject {
            static let shared = Items()
            @Published var names: [String] = []

            init() {
                _ = Result(catching: {
                    guard let url = Bundle.module.url(forResource: "fish", withExtension: nil) else {
                        throw APIError.message(reason: "missing")
                    }
                    return try Data(contentsOf: url)
                })
                .publisher
                .decode(type: FileResponse.self, decoder: JSONDecoder())
                .mapError { _ in APIError.message(reason: "parse") }
                .subscribe(on: DispatchQueue.main)
                .eraseToAnyPublisher()
                .replaceError(with: FileResponse(total: 0, results: []))
                .map { $0.results.map(\\.name) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] names in
                    self?.names = names
                }
            }
        }

        enum APIError: Error {
            case message(reason: String)
        }

        final class RowsModel: ObservableObject {
            @Published var rows: [String] = []
            var cancellable: Any?

            init() {
                cancellable = Items.shared.$names
                    .map { $0.sorted() }
                    .sink { [weak self] in
                        self?.rows = $0
                    }
            }
        }

        struct ContentView: View {
            @StateObject private var model = RowsModel()

            var body: some View {
                ForEach(model.rows, id: \\.self) { row in
                    Text(row)
                }
            }
        }
        """
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("Goldfish") && strings.contains("Anchovy"),
                "bundled bytes must ride the pipeline into rendered rows, got \(strings)")
    }
}

@Suite struct EnumKeyedPublishedDictTests {
    // ACHNBrowser's Items environment: init loops CaseIterable categories,
    // a private method subscript-assigns into an enum-keyed @Published
    // dictionary, and views read counts back through the same subscript.
    @Test func subscriptWritesReadBackByEnumKey() throws {
        let source = """
        enum Category: String, CaseIterable {
            case fish, bugs, fossils
        }
        final class Items: ObservableObject {
            static let shared = Items()
            @Published var categories: [Category: [String]] = [:]
            init() {
                for category in Category.allCases {
                    process(category: category, items: ["a-\\(category.rawValue)", "b"])
                }
            }
            private func process(category: Category, items: [String]) {
                var items = items
                items.append("c")
                let finalItems = items.map { $0 }
                categories[category] = finalItems
            }
            func count(for category: Category) -> Int {
                categories[category]?.count ?? 0
            }
        }
        let shared = Items.shared
        let direct = shared.categories[Category.fish]?.count ?? 0
        let viaFunc = shared.count(for: .fish)
        let total = shared.categories.count
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("direct")?.stringified == "3")
        #expect(interpreter.globals.lookup("viaFunc")?.stringified == "3")
        #expect(interpreter.globals.lookup("total")?.stringified == "3")
    }
}

@Suite struct EnumSelfAssignInitTests {
    // ACHNBrowser's Category: declared init with `self = .case`
    // assignments falling back to the synthesized rawValue init with
    // mixed implicit/explicit raw strings. Native: "Fish" → .fish.
    @Test func declaredInitWithRawValueFallback() throws {
        let source = """
        enum Category: String, CaseIterable {
            case housewares, miscellaneous
            case wallMounted = "wall-mounted"
            case dressup = "Dress-Up"
            case other
            case art, bugs, fish, fossils
            case seaCreatures = "Sea Creatures"
            init(itemCategory: String) {
                if itemCategory == "Fish - North" || itemCategory == "Fish - South" {
                    self = .fish
                    return
                } else if itemCategory == "Sea Creatures" {
                    self = .seaCreatures
                    return
                }
                self = Category(rawValue: itemCategory.lowercased()) ?? .other
            }
        }
        struct Item {
            let category: String
            var appCategory: Category { Category(itemCategory: category) }
        }
        let items = [Item(category: "Fish"), Item(category: "Housewares"), Item(category: "Fish - North")]
        let fish = items.filter { $0.appCategory == Category.fish }
        let fishCount = fish.count
        let houseCount = items.filter { $0.appCategory == .housewares }.count
        let direct = Category(rawValue: "fish") == Category.fish
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("fishCount")?.stringified == "2")
        #expect(interpreter.globals.lookup("houseCount")?.stringified == "1")
        #expect(interpreter.globals.lookup("direct")?.stringified == "true")
    }
}

@Suite struct DecodedEnumFilterTests {
    // The full ACHNBrowser items path: structural decode of a wrapper
    // response, then filtering by a computed enum property on the DECODED
    // instances. Native keeps both fish.
    @Test func decodedItemsFilterByComputedEnum() throws {
        let source = """
        enum Category: String, CaseIterable {
            case housewares, fish, other
            init(itemCategory: String) {
                if itemCategory == "Fish - North" {
                    self = .fish
                    return
                }
                self = Category(rawValue: itemCategory.lowercased()) ?? .other
            }
        }
        struct Item: Codable, Equatable {
            static func ==(lhs: Item, rhs: Item) -> Bool {
                lhs.name == rhs.name && lhs.appCategory == rhs.appCategory
            }
            let name: String
            let category: String
            var appCategory: Category { Category(itemCategory: category) }
        }
        struct ItemWrapper: Codable {
            let id: Int
            let name: String
            var content: Item
        }
        struct NewItemResponse: Codable {
            let total: Int
            let results: [ItemWrapper]
        }
        let json = \"\"\"
        {"total": 2,
         "results": [
           {"id": 1, "name": "anchovy", "content": {"name": "Anchovy", "category": "Fish"}},
           {"id": 2, "name": "chair", "content": {"name": "Chair", "category": "Housewares"}}
         ]}
        \"\"\"
        let data = json.data(using: .utf8)!
        let response = try! JSONDecoder().decode(NewItemResponse.self, from: data)
        let decodedCount = response.results.count
        let firstCategory = response.results[0].content.category
        let fishItems = response.results.filter { $0.content.appCategory == Category.fish }
        let fishCount = fishItems.count
        let fishName = fishItems.first?.content.name ?? "NONE"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("decodedCount")?.stringified == "2")
        #expect(interpreter.globals.lookup("firstCategory")?.stringified == "Fish")
        #expect(interpreter.globals.lookup("fishCount")?.stringified == "1")
        #expect(interpreter.globals.lookup("fishName")?.stringified == "Anchovy")
    }
}

@Suite struct NestedShorthandClosureTests {
    // `numbers.map { $0.filter { $0 % 2 == 0 } }` — the inner closure's $0
    // must shadow the outer's (ACHNBrowser filters inside a publisher map).
    @Test func nestedDollarZeroShadows() throws {
        let source = """
        let numbers = [[1, 2, 3], [4, 5]]
        let evens = numbers.map { $0.filter { $0 % 2 == 0 } }
        let flat = evens.flatMap { $0 }
        let counts = evens.map { $0.count }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("flat")?.stringified == "[2, 4]")
        #expect(interpreter.globals.lookup("counts")?.stringified == "[1, 1]")
    }
}

@Suite struct DeferredGenericDecodeTests {
    // ACHNBrowser's ItemsAPI.fetchFile<T: Codable>: `.decode(type: T.self)`
    // runs with T UNRESOLVED inside the factory — natively T pins from the
    // caller's `.replaceError(with: NewItemResponse(...))`. The data rides
    // pending until the typed fallback names the type.
    @Test func replaceErrorFallbackResolvesDeferredDecode() throws {
        let previousRoot = BundleBox.projectResourceRoot
        let root = NSTemporaryDirectory() + "deferred-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root + "/Resources/json", withIntermediateDirectories: true)
        defer {
            BundleBox.projectResourceRoot = previousRoot
            try? FileManager.default.removeItem(atPath: root)
        }
        try #"{"total": 2, "results": [{"name": "Goldfish", "category": "Fish"}, {"name": "Chair", "category": "Housewares"}]}"#
            .write(toFile: root + "/Resources/json/fish", atomically: true, encoding: .utf8)
        BundleBox.projectResourceRoot = root
        let source = """
        import Combine

        struct ItemRow: Codable {
            let name: String
            let category: String
        }

        struct FileResponse: Codable {
            let total: Int
            let results: [ItemRow]
        }

        enum APIError: Error {
            case parseError(String)
        }

        struct FileAPI {
            static func fetchFile<T: Codable>(name: String) -> AnyPublisher<T, APIError> {
                Result(catching: {
                    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: nil)!)
                })
                .publisher
                .decode(type: T.self, decoder: JSONDecoder())
                .mapError { APIError.parseError("\\($0)") }
                .eraseToAnyPublisher()
            }
        }

        var fishNames: [String] = []
        _ = FileAPI.fetchFile(name: "fish")
            .replaceError(with: FileResponse(total: 0, results: []))
            .eraseToAnyPublisher()
            .map { $0.results.filter { $0.category == "Fish" } }
            .sink { items in
                fishNames = items.map { $0.name }
            }
        let count = fishNames.count
        let first = fishNames.first ?? "NONE"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("count")?.stringified == "1")
        #expect(interpreter.globals.lookup("first")?.stringified == "Goldfish")
    }
}

@Suite struct LexicalTypeScopingTests {
    // clean-architecture's triangle: module-level APIError, a conforming
    // test double whose EXTENSION nests a DIFFERENT APIError, and
    // protocol-extension bodies throwing bare `APIError.…` — natively
    // those bare names resolve LEXICALLY (module scope), never through
    // the runtime self's nested types.
    @Test func protocolExtensionSeesModuleScope() throws {
        let source = """
        enum APIError: Swift.Error, Equatable {
            case invalidURL
            case unexpectedResponse
        }
        protocol APICall {
            var path: String { get }
        }
        extension APICall {
            func urlRequest(baseURL: String) throws -> String {
                guard !path.isEmpty else {
                    throw APIError.invalidURL
                }
                return baseURL + path
            }
        }
        protocol WebRepositoryProto {
            var baseURL: String { get }
        }
        extension WebRepositoryProto {
            func call(endpoint: APICall) throws -> String {
                let request = try endpoint.urlRequest(baseURL: baseURL)
                guard request.hasPrefix("https") else {
                    throw APIError.unexpectedResponse
                }
                return request
            }
        }
        final class TestWebRepository: WebRepositoryProto {
            let baseURL = "http://test.com"
        }
        extension TestWebRepository {
            enum API: APICall {
                case test
                case urlError
                var path: String {
                    if self == .urlError { return "" }
                    return "/path"
                }
            }
        }
        extension TestWebRepository {
            enum APIError: Swift.Error {
                case fail
            }
        }
        final class RepoTests {
            let sut = TestWebRepository()
            func loadURLError() -> Bool {
                do {
                    _ = try sut.call(endpoint: TestWebRepository.API.urlError)
                    return false
                } catch let error as APIError {
                    return error == APIError.invalidURL
                } catch {
                    return false
                }
            }
            func loadBadScheme() -> Bool {
                do {
                    _ = try sut.call(endpoint: TestWebRepository.API.test)
                    return false
                } catch let error as APIError {
                    return error == APIError.unexpectedResponse
                } catch {
                    return false
                }
            }
        }
        let tests = RepoTests()
        let urlErrorMatches = tests.loadURLError()
        let schemeErrorMatches = tests.loadBadScheme()
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("urlErrorMatches")?.stringified == "true")
        #expect(interpreter.globals.lookup("schemeErrorMatches")?.stringified == "true")
    }
}

@Suite struct URLProtocolMockStoreTests {
    // clean-architecture's RequestMocking store: an NSLock-guarded static
    // container, mocks matched by real URL equality against a URLRequest
    // built in a protocol extension.
    @Test func lockGuardedStoreMatchesRequestURL() throws {
        let source = """
        struct MockedResponse {
            let url: URL
            let payload: String
        }
        final class MocksContainer {
            var mocks: [MockedResponse] = []
        }
        enum Store {
            static private let container = MocksContainer()
            static private let lock = NSLock()
            static func add(mock: MockedResponse) {
                lock.withLock {
                    container.mocks.append(mock)
                }
            }
            static func mock(for request: URLRequest) -> MockedResponse? {
                return lock.withLock {
                    container.mocks.first { $0.url == request.url }
                }
            }
            static func canInit(with request: URLRequest) -> Bool {
                return mock(for: request) != nil
            }
        }
        protocol Call {
            var path: String { get }
        }
        extension Call {
            func urlRequest(baseURL: String) throws -> URLRequest {
                guard let url = URL(string: baseURL + path) else {
                    fatalError("bad url")
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                return request
            }
        }
        enum API: Call {
            case test
            var path: String { "/test/path" }
        }
        let baseURL = "https://test.com"
        Store.add(mock: MockedResponse(url: URL(string: baseURL + "/test/path")!, payload: "hi"))
        let request = try API.test.urlRequest(baseURL: baseURL)
        let matched = Store.canInit(with: request)
        let found = Store.mock(for: request)?.payload ?? "NONE"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("matched")?.stringified == "true")
        #expect(interpreter.globals.lookup("found")?.stringified == "hi")
    }
}

@Suite struct StoreKeyPathAppendingTests {
    // clean-architecture's pushFirstResolveStatus: the permission keyPath is
    // BUILT (`pathToPermissions.appending(path: \.push)`) then drives the
    // Store subscript write — native KeyPath concatenation.
    @Test func appendedKeyPathWritesThroughStore() throws {
        let source = """
        import Combine

        struct Permissions: Equatable { var push: String = "unknown" }
        struct AppState: Equatable {
            var permissions = Permissions()
            static func permissionKeyPath() -> WritableKeyPath<AppState, String> {
                let pathToPermissions = \\AppState.permissions
                return pathToPermissions.appending(path: \\.push)
            }
        }
        typealias Store<State> = CurrentValueSubject<State, Never>
        extension Store {
            subscript<T>(keyPath: WritableKeyPath<Output, T>) -> T where Failure == Never {
                get { value[keyPath: keyPath] }
                set {
                    var value = self.value
                    value[keyPath: keyPath] = newValue
                    self.value = value
                }
            }
        }
        let store = Store<AppState>(AppState())
        let keyPath = AppState.permissionKeyPath()
        store[keyPath] = "granted"
        let after = store.value.permissions.push
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("after")?.stringified == "granted")
    }
}

@Suite struct SeededRNGParityTests {
    // FoodTruck's SeededRandomGenerator genre: srand48/drand48 are REAL
    // libc calls, UInt64 is an exact 64-bit host carrier (not Int-clamped),
    // and random(in:using:)/shuffled(using:)/prefix(.random(...)) drive the
    // REAL stdlib algorithms through the interpreted generator. Native
    // parity: seed 1's first draw is 767944315707129856; ranged draws
    // below reproduce a compiled run of the same source bit-for-bit.
    @Test func seededStreamMatchesNative() throws {
        let source = """
        struct Gen: RandomNumberGenerator {
            init(seed: Int) { srand48(seed) }
            func next() -> UInt64 {
                UInt64(drand48() * Double(UInt64.max))
            }
        }
        var g = Gen(seed: 1)
        let raw = g.next()
        let ranged = Int.random(in: 1 ... 5, using: &g)
        let dbl = Double.random(in: 0.75 ... 1.1, using: &g)
        var g2 = Gen(seed: 2)
        let picked = [10, 20, 30, 40, 50].shuffled(using: &g2).prefix(.random(in: 1 ... 3, using: &g2)).count
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("raw")?.stringified == "767944315707129856")
        #expect(interpreter.globals.lookup("ranged")?.stringified == "3")
        // Native run (scratch swiftc): dbl == 1.0421860263584204 exactly.
        #expect(interpreter.globals.lookup("dbl")?.stringified == "1.0421860263584204")
        let picked = interpreter.globals.lookup("picked")?.intValue ?? -1
        #expect((1...3).contains(picked))
    }
}

@Suite struct RealTableGatewayTests {
    // FoodTruck R2's orders screen: a REAL SwiftUI Table (NSTableView-
    // backed) builds from the interpreted TableColumn DSL — columns-only
    // form with a rows: builder of TableRow marks — and `#if os(...)`
    // interprets per Interpreter.interpretsAsPlatform (macOS for the twin,
    // iOS corpus default).
    @Test func tableBuildsAndPlatformKnobHolds() throws {
        #expect(Interpreter.interpretsAsPlatform == "iOS") // corpus default
        let registry = ViewRegistry()
        #expect(registry.constructor(named: "Table") != nil)
        #expect(registry.constructor(named: "TableColumn") != nil)
        #expect(registry.modifier(named: "tableStyle") != nil)
        let source = """
        struct Row: Identifiable {
            let id: Int
            let name: String
        }
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    Table(selection: .constant(Set<Int>())) {
                        TableColumn("Name") { (row: Row) in
                            Text(row.name)
                        }
                        TableColumn("Id") { (row: Row) in
                            Text(String(row.id))
                        }
                    } rows: {
                        ForEach([Row(id: 1, name: "a"), Row(id: 2, name: "b")]) { row in
                            TableRow(row)
                        }
                    }
                    .tableStyle(.inset)
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success = rendered else {
            Issue.record("table render failed")
            return
        }
    }
}

@Suite struct RealRegistryChromeTests {
    // FoodTruck R2's blank-screen class: `.toolbar`/`.toolbarRole` were
    // unregistered in the REAL registry, so the whole modified subtree
    // absorbed into a marker and painted BLANK. They pass the view through
    // (borderless captures show no toolbar chrome natively either), and
    // GeometryReader renders its content with the real proxy.
    @Test func toolbarAndGeometryReaderKeepViewsRenderable() throws {
        let registry = ViewRegistry()
        #expect(registry.modifier(named: "toolbar") != nil)
        #expect(registry.modifier(named: "toolbarRole") != nil)
        #expect(registry.constructor(named: "GeometryReader") != nil)
        let source = """
        @main
        struct P: App {
            var body: some Scene {
                WindowGroup {
                    GeometryReader { proxy in
                        Text("W\\(Int(proxy.size.width))")
                    }
                    .toolbar {
                        Button("B") { }
                    }
                }
            }
        }
        """
        let rendered = InterpreterHost().render(source: source, lazyTopLevelGlobals: true)
        guard case .success = rendered else {
            Issue.record("render failed")
            return
        }
    }
}

@Suite struct ModuleQualifiedAndCollisionTests {
    // FoodTruck's city/salesHistory rungs: `Swift.max(...)` strips the
    // module qualifier (the merge has no modules), and a stored property
    // sharing its name with a method (`dailyOrderSummaries` dict beside
    // `dailyOrderSummaries(cityID:)`) dispatches the METHOD at call sites
    // with arguments — native overload resolution.
    @Test func moduleQualifierAndOwnMethodCollision() throws {
        let source = """
        let clamped = Swift.min(Swift.max(7, 0), 5)

        final class Model {
            var summaries: [Int: [String]] = [1: ["a", "b"], 2: ["c"]]
            func summaries(cityID: Int) -> [String] {
                guard let result = summaries[cityID] else { return [] }
                return result
            }
        }
        let model = Model()
        let viaMethod = model.summaries(cityID: 1).count
        let viaProperty = model.summaries.count
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("clamped")?.stringified == "5")
        #expect(interpreter.globals.lookup("viaMethod")?.stringified == "2")
        #expect(interpreter.globals.lookup("viaProperty")?.stringified == "2")
    }

    // Interactive_Header's shape: a local `enum Tab` beside SwiftUI.Tab —
    // the module qualifier explicitly BYPASSES the declared type, so the
    // framework path answers (an absorbing view node under the trace
    // registry), never the local enum's missing `init`.
    @Test func qualifiedTypeBypassesLocalDeclaration() throws {
        let source = """
        import SwiftUI

        enum Tab {
            case chat
            case friends
        }

        let qualified = SwiftUI.Tab.init(value: Tab.chat) { Text("Chat") }
        let stillWorks = Swift.max(3, 9)
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("stillWorks")?.stringified == "9")
        let qualified = interpreter.globals.lookup("qualified")
        #expect(qualified != nil)
        if case .enumType = qualified { Issue.record("local enum answered a qualified access") }
    }
}

@Suite struct SortedUsingComparatorTests {
    // FoodTruck's OrdersView: `.sorted(using: [KeyPathComparator(\\.status,
    // order: .reverse)])` over Comparable enums (SE-0266: declaration
    // order) and navigationTitle chrome counting as rendered content.
    // Native run (scratch swiftc): first=3 last=2 less=true.
    @Test func keyPathComparatorSort() throws {
        let source = """
        enum Status: Int, Codable, Comparable {
            case placed, preparing, ready, completed
        }
        struct Order2 {
            let id: Int
            let status: Status
        }
        let orders = [Order2(id: 1, status: .ready), Order2(id: 2, status: .placed), Order2(id: 3, status: .completed)]
        let sorted = orders.sorted(using: [KeyPathComparator(\\Order2.status, order: .reverse)])
        let first = sorted.first?.id ?? -1
        let last = sorted.last?.id ?? -1
        let less = Status.placed < Status.ready
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("first")?.stringified == "3")
        #expect(interpreter.globals.lookup("last")?.stringified == "2")
        #expect(interpreter.globals.lookup("less")?.stringified == "true")
    }
}

@Suite struct DictionaryPipelineTests {
    // FoodTruck's order-summary pipeline: Dictionary(uniqueKeysWithValues:)
    // and (grouping:by:) construct real dictionaries, for-in yields
    // (key, value) tuples, and reduce(into: .empty) resolves its marker
    // seed against the ambient return annotation — stdlib semantics.
    @Test func summariesGenreRoundTrip() throws {
        let source = """
        struct Summary: Equatable {
            var sales: [Int: Int] = [:]
            static let empty = Summary()
            mutating func formUnion(_ other: Summary) {
                for (key, value) in other.sales {
                    sales[key, default: 0] += value
                }
            }
        }

        let pairs = [(1, Summary(sales: [7: 2])), (2, Summary(sales: [7: 3, 9: 1]))]
        let byCity = Dictionary(uniqueKeysWithValues: pairs)
        let cityCount = byCity.count

        func combined() -> Summary {
            return byCity.values.reduce(into: .empty) { partialResult, summary in
                partialResult.formUnion(summary)
            }
        }
        let total = combined()
        let sevenTotal = total.sales[7] ?? 0
        let nineTotal = total.sales[9] ?? 0

        let grouped = Dictionary(grouping: [1, 2, 3, 4, 5], by: { $0 % 2 })
        let evens = grouped[0]?.count ?? 0
        let odds = grouped[1]?.count ?? 0
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("cityCount")?.stringified == "2")
        #expect(interpreter.globals.lookup("sevenTotal")?.stringified == "5")
        #expect(interpreter.globals.lookup("nineTotal")?.stringified == "1")
        #expect(interpreter.globals.lookup("evens")?.stringified == "2")
        #expect(interpreter.globals.lookup("odds")?.stringified == "3")
    }
}

@Suite struct LocalizedStringInitTests {
    // FoodTruck's donut/city names: `String(localized:bundle:comment:)` —
    // no catalogs load headlessly, so the KEY is the development-language
    // value (identical to an unlocalized native run).
    @Test func localizedInitYieldsKey() throws {
        let source = """
        import Foundation

        let name = String(localized: "The Classic", bundle: .module, comment: "A donut-flavor name.")
        let bare = String(localized: "Blueberry Frosted")
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("name")?.stringified == "The Classic")
        #expect(interpreter.globals.lookup("bare")?.stringified == "Blueberry Frosted")
    }
}

@Suite struct ArrayIndexArithmeticTests {
    // MakeItSo's computeOrder genre: Collection index arithmetic on the
    // Int-indexed array model — index(after:)/index(before:)/
    // index(_:offsetBy:) are stdlib-defined (+1/-1/+offset).
    @Test func indexAfterBeforeOffset() throws {
        let source = """
        extension Array {
            func slot(after index: Int) -> Int {
                guard self.count > 0 else { return 0 }
                let nextIndex = self.index(after: index)
                return nextIndex < self.endIndex ? 1 : 2
            }
        }
        let values = [10, 20, 30]
        let mid = values.slot(after: 0)
        let end = values.slot(after: 2)
        let back = values.index(before: 2)
        let jump = values.index(0, offsetBy: 2)
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("mid")?.stringified == "1")
        #expect(interpreter.globals.lookup("end")?.stringified == "2")
        #expect(interpreter.globals.lookup("back")?.stringified == "1")
        #expect(interpreter.globals.lookup("jump")?.stringified == "2")
    }
}

@Suite struct ImageDownloadPipelineTests {
    // clean-architecture's ImageWebRepositoryTests genre, end to end:
    // `UIColor.red.image(size)` renders a REAL pixel-exact bitmap through
    // the UIGraphicsImageRenderer bridge (UIColor extensions dispatch on
    // absorbed Colors), `session.download(from: url)` wraps the bare URL
    // in a URLRequest before URLProtocol.canInit, serves mocked bytes via
    // a temp file, and failure mocks throw the ORIGINAL NSError. Native
    // baseline: the app's own upstream-passing tests.
    @Test func downloadRoundTripAndFailureDomain() throws {
        let source = """
        import Foundation
        import UIKit

        struct MockedResponse {
            let url: URL
            let result: Result<Data, Swift.Error>
        }
        final class MocksContainer {
            var mocks: [MockedResponse] = []
        }
        final class RequestMocking: URLProtocol {
            static let container = MocksContainer()
            static func add(_ mock: MockedResponse) { container.mocks.append(mock) }
            static func removeAll() { container.mocks.removeAll() }
            static func mock(for request: URLRequest) -> MockedResponse? {
                container.mocks.first { $0.url == request.url }
            }
            override class func canInit(with request: URLRequest) -> Bool {
                mock(for: request) != nil
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let mock = RequestMocking.mock(for: request), let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                switch mock.result {
                case let .success(data):
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                case let .failure(error):
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() { }
        }

        extension URLSession {
            static var mocked: URLSession {
                let configuration = URLSessionConfiguration.default
                configuration.protocolClasses = [RequestMocking.self]
                return URLSession(configuration: configuration)
            }
        }

        extension UIColor {
            func image(_ size: CGSize) -> UIImage {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
                    setFill()
                    rendererContext.fill(CGRect(origin: .zero, size: size))
                }
            }
        }

        let session = URLSession.mocked
        let url = URL(string: "https://image.service.com/myimage.png")!
        let testImage = UIColor.red.image(CGSize(width: 40, height: 40))
        RequestMocking.add(MockedResponse(url: url, result: .success(testImage.pngData()!)))
        let (localURL, _) = try await session.download(from: url)
        let bytes = try Data(contentsOf: localURL)
        let decoded = UIImage(data: bytes)
        let sizeMatches = decoded?.size == testImage.size

        RequestMocking.removeAll()
        let refError = NSError(domain: "test", code: 7)
        RequestMocking.add(MockedResponse(url: url, result: .failure(refError)))
        var caughtDomain = ""
        do {
            _ = try await session.download(from: url)
        } catch {
            let nsError = error as NSError
            caughtDomain = nsError.domain
        }
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("sizeMatches")?.stringified == "true")
        #expect(interpreter.globals.lookup("caughtDomain")?.stringified == "test")
    }
}

@Suite struct HostEnumExtensionTests {
    // clean-architecture's UNAuthorizationStatus.map: user extensions of a
    // HOST enum dispatch on TYPED markers (minted at `Type.case` and at
    // stored-property annotations), and `switch self` inside the extension
    // matches marker case names. Native run: all three flags true.
    @Test func extensionMemberOnHostEnumMarker() throws {
        let source = """
        import UserNotifications

        enum Permission {
            case pushNotifications
            enum Status: Equatable { case unknown, notRequested, granted, denied }
        }

        extension UNAuthorizationStatus {
            var map: Permission.Status {
                switch self {
                case .denied: return .denied
                case .authorized: return .granted
                case .notDetermined, .provisional, .ephemeral: return .notRequested
                @unknown default: return .notRequested
                }
            }
        }

        struct Settings {
            var authorizationStatus: UNAuthorizationStatus
        }

        let mappedNotDetermined = UNAuthorizationStatus.notDetermined.map == .notRequested
        let mappedAuthorized = UNAuthorizationStatus.authorized.map == .granted
        let s = Settings(authorizationStatus: .authorized)
        let viaProperty = s.authorizationStatus.map == .granted
        let unknownRaw = UNAuthorizationStatus(rawValue: 10)?.map == Permission.Status.notRequested
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("mappedNotDetermined")?.stringified == "true")
        #expect(interpreter.globals.lookup("mappedAuthorized")?.stringified == "true")
        #expect(interpreter.globals.lookup("viaProperty")?.stringified == "true")
        #expect(interpreter.globals.lookup("unknownRaw")?.stringified == "true")
    }
}

@Suite struct CountryModelRoundTripTests {
    // The exact ApiModel.Country shape: [String: String?] translations, an
    // optional URL under a REMAPPED CodingKey (flag <-> alpha2Code), and a
    // custom init(from:) that structural decode SKIPS (documented
    // divergence). Native: the encode->decode round trip preserves equality.
    @Test func encodeDecodeRoundTripPreservesEquality() throws {
        let source = """
        import Foundation

        struct Country: Codable, Equatable {
            let name: String
            let translations: [String: String?]
            let population: Int
            let flag: URL?
            let alpha3Code: String

            enum CodingKeys: String, CodingKey {
                case name
                case translations
                case population
                case flag = "alpha2Code"
                case alpha3Code
            }

            init(name: String, translations: [String: String?], population: Int, flag: URL?, alpha3Code: String) {
                self.name = name
                self.translations = translations
                self.population = population
                self.flag = flag
                self.alpha3Code = alpha3Code
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                name = try values.decode(String.self, forKey: .name)
                translations = try values.decode([String: String?].self, forKey: .translations)
                population = try values.decode(Int.self, forKey: .population)
                if let alpha2orFlagURL = try? values.decode(String.self, forKey: .flag) {
                    let urlString = alpha2orFlagURL.count == 2 ?
                    "https://flagcdn.com/w640/\\(alpha2orFlagURL.lowercased()).jpg" : alpha2orFlagURL
                    flag = URL(string: urlString)
                } else { flag = nil }
                alpha3Code = try values.decode(String.self, forKey: .alpha3Code)
            }
        }

        let data = [
            Country(name: "United States", translations: [:], population: 125000000,
                    flag: URL(string: "https://flagcdn.com/w640/us.jpg"), alpha3Code: "USA"),
            Country(name: "Georgia", translations: [:], population: 2340000, flag: nil, alpha3Code: "GEO")
        ]
        var thrown = ""
        var equal = false
        var count = 0
        var fieldDiff = ""
        do {
            let bytes = try JSONEncoder().encode(data)
            let decoded = try JSONDecoder().decode([Country].self, from: bytes)
            equal = decoded == data
            count = decoded.count
            if count == 2 {
                for i in 0 ..< 2 {
                    let a = decoded[i], b = data[i]
                    if a.name != b.name { fieldDiff += "name\\(i):\\(a.name)|" }
                    if a.translations != b.translations { fieldDiff += "translations\\(i):\\(a.translations)|" }
                    if a.population != b.population { fieldDiff += "population\\(i):\\(a.population)|" }
                    if a.flag != b.flag { fieldDiff += "flag\\(i):\\(String(describing: a.flag)) vs \\(String(describing: b.flag))|" }
                    if a.alpha3Code != b.alpha3Code { fieldDiff += "alpha3\\(i):\\(a.alpha3Code)|" }
                }
            }
        } catch {
            thrown = "\\(error)"
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("thrown")?.stringified == "")
        #expect(interpreter.globals.lookup("count")?.stringified == "2")
        #expect(interpreter.globals.lookup("fieldDiff")?.stringified == "")
        #expect(interpreter.globals.lookup("equal")?.stringified == "true")
    }

    // countryDetailsSuccess's shape: namespaced nested models, a nested
    // struct ARRAY, and an optional array member.
    @Test func namespacedNestedModelRoundTrip() throws {
        let source = """
        import Foundation

        enum ApiModel { }

        extension ApiModel {
            struct Currency: Codable, Equatable {
                let code: String
                let symbol: String?
                let name: String
            }
        }

        extension ApiModel {
            struct CountryDetails: Codable, Equatable {
                let capital: String
                let currencies: [Currency]
                let borders: [String]?
            }
        }

        let value = ApiModel.CountryDetails(
            capital: "London",
            currencies: [ApiModel.Currency(code: "12", symbol: "$", name: "US dollar")],
            borders: ["USA", "GEO", "CAN"])
        var thrown = ""
        var equal = false
        var diff = ""
        do {
            let bytes = try JSONEncoder().encode([value])
            let decoded = try JSONDecoder().decode([ApiModel.CountryDetails].self, from: bytes)
            if let first = decoded.first {
                equal = first == value
                if first.capital != value.capital { diff += "capital:\\(first.capital)|" }
                if first.currencies != value.currencies { diff += "currencies:\\(first.currencies)|" }
                if first.borders != value.borders { diff += "borders:\\(String(describing: first.borders))|" }
            } else {
                diff = "EMPTY"
            }
        } catch {
            thrown = "\\(error)"
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("thrown")?.stringified == "")
        #expect(interpreter.globals.lookup("diff")?.stringified == "")
        #expect(interpreter.globals.lookup("equal")?.stringified == "true")
    }
}

@Suite struct StoreValueSemanticsTests {
    // clean-architecture's DeepLinksHandlerTests genre: the Store
    // (CurrentValueSubject) has NATIVE value semantics at its boundary —
    // the seed is copied in, reads copy out, so mutating the store never
    // touches caller-held values and earlier reads stay frozen. Native
    // run (scratch swiftc): all four flags true.
    @Test func storeBoundaryCopies() throws {
        let source = """
        import Combine

        struct Routing: Equatable { var code: String? }
        struct AppState: Equatable { var routing = Routing() }

        typealias Store<State> = CurrentValueSubject<State, Never>

        extension Store {
            subscript<T>(keyPath: WritableKeyPath<Output, T>) -> T where Failure == Never {
                get { value[keyPath: keyPath] }
                set {
                    var value = self.value
                    value[keyPath: keyPath] = newValue
                    self.value = value
                }
            }
        }

        let initialState = AppState()
        let store = Store<AppState>(initialState)
        store[\\.routing.code] = "ITA"
        let localUntouched = initialState.routing.code == nil
        let storeUpdated = store.value.routing.code == "ITA"
        var expected = AppState()
        expected.routing.code = "ITA"
        let equalsExpected = store.value == expected
        let earlier = store.value
        store[\\.routing.code] = "FRA"
        let earlierReadUnaffected = earlier.routing.code == "ITA"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("localUntouched")?.stringified == "true")
        #expect(interpreter.globals.lookup("storeUpdated")?.stringified == "true")
        #expect(interpreter.globals.lookup("equalsExpected")?.stringified == "true")
        #expect(interpreter.globals.lookup("earlierReadUnaffected")?.stringified == "true")
    }
}

@Suite struct LoadableBindingSequenceTests {
    // clean-architecture's LoadableTests.loadSuccess, end to end: the
    // Binding's generic argument resolves get()/set() values to real cases,
    // setIsLoading mutates through the host-self lvalue, the Task-run
    // resource lands `.loaded`, and the expected literal's payload markers
    // resolve against the enum before the declared == runs. Native run
    // (scratch swiftc): count=2 sequenceMatches=true.
    @Test func bindingLoadSequenceEquality() throws {
        let source = """
        import SwiftUI
        import Combine

        final class CancelBag {
            fileprivate(set) var subscriptions = [any Cancellable]()
            private let equalToAny: Bool
            init(equalToAny: Bool = false) { self.equalToAny = equalToAny }
            func cancel() { subscriptions.removeAll() }
            func isEqual(to other: CancelBag) -> Bool { other === self || other.equalToAny || self.equalToAny }
        }
        extension CancelBag {
            static var test: CancelBag { CancelBag(equalToAny: true) }
        }
        extension Cancellable {
            func store(in cancelBag: CancelBag) { cancelBag.subscriptions.append(self) }
        }
        extension Task: Cancellable { }

        enum Loadable<T> {
            case notRequested
            case isLoading(last: T?, cancelBag: CancelBag)
            case loaded(T)
            case failed(Error)

            var value: T? {
                switch self {
                case let .loaded(value): return value
                case let .isLoading(last, _): return last
                default: return nil
                }
            }
            mutating func setIsLoading(cancelBag: CancelBag) {
                self = .isLoading(last: value, cancelBag: cancelBag)
            }
        }
        extension Loadable: Equatable where T: Equatable {
            static func == (lhs: Loadable<T>, rhs: Loadable<T>) -> Bool {
                switch (lhs, rhs) {
                case (.notRequested, .notRequested): return true
                case let (.isLoading(lhsV, lhsC), .isLoading(rhsV, rhsC)):
                    return lhsV == rhsV && lhsC.isEqual(to: rhsC)
                case let (.loaded(lhsV), .loaded(rhsV)): return lhsV == rhsV
                case let (.failed(lhsE), .failed(rhsE)):
                    return lhsE.localizedDescription == rhsE.localizedDescription
                default: return false
                }
            }
        }

        typealias LoadableSubject<Value> = Binding<Loadable<Value>>

        extension LoadableSubject {
            func load<T>(_ resource: @escaping () async throws -> T) where Value == Loadable<T> {
                let cancelBag = CancelBag()
                wrappedValue.setIsLoading(cancelBag: cancelBag)
                let task = Task {
                    do {
                        wrappedValue = .loaded(try await resource())
                    } catch {
                        wrappedValue = .failed(error)
                    }
                }
                task.store(in: cancelBag)
            }
        }

        var values: [Loadable<String>] = []
        let sut = Binding<Loadable<String>>(get: {
            values.last ?? .notRequested
        }, set: {
            values.append($0)
        })
        sut.load {
            return "test"
        }
        let sequenceMatches = values == [.isLoading(last: nil, cancelBag: .test), .loaded("test")]
        let count = values.count
            let sequenceMatches = values == [.isLoading(last: nil, cancelBag: .test), .loaded("test")]
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("count")?.stringified == "2")
        #expect(interpreter.globals.lookup("sequenceMatches")?.stringified == "true")
    }
}

@Suite struct CancelBagStoreTests {
    // clean-architecture's LoadableTests.cancelLoading genre: a user
    // `extension Cancellable { store(in:) }` applies to HOST cancellables
    // (PassthroughSubject sink returns), the bag counts real entries, and
    // the mutating enum method cancels + writes self back. Native run:
    // count1Before=1 count1After=0 errorSet=true value2=7.
    @Test func sinkStoreCountAndCancelLoading() throws {
        let source = """
        import Combine

        final class CancelBag {
            fileprivate(set) var subscriptions = [any Cancellable]()
            private let equalToAny: Bool
            init(equalToAny: Bool = false) { self.equalToAny = equalToAny }
            func cancel() { subscriptions.removeAll() }
            func isEqual(to other: CancelBag) -> Bool { other === self || other.equalToAny || self.equalToAny }
        }
        extension Cancellable {
            func store(in cancelBag: CancelBag) { cancelBag.subscriptions.append(self) }
        }

        enum Loadable<T> {
            case notRequested
            case isLoading(last: T?, cancelBag: CancelBag)
            case loaded(T)
            case failed(Error)

            var value: T? {
                switch self {
                case let .loaded(value): return value
                case let .isLoading(last, _): return last
                default: return nil
                }
            }
            var error: Error? {
                switch self {
                case let .failed(error): return error
                default: return nil
                }
            }

            mutating func cancelLoading() {
                switch self {
                case let .isLoading(last, cancelBag):
                    cancelBag.cancel()
                    if let last = last {
                        self = .loaded(last)
                    } else {
                        let error = NSError(
                            domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Canceled by user", comment: "")])
                        self = .failed(error)
                    }
                default: break
                }
            }
        }

        let cancelBag1 = CancelBag(), cancelBag2 = CancelBag()
        let subject = PassthroughSubject<Int, Never>()
        subject.sink { _ in }.store(in: cancelBag1)
        subject.sink { _ in }.store(in: cancelBag2)
        var sut1 = Loadable<Int>.isLoading(last: nil, cancelBag: cancelBag1)
        let count1Before = cancelBag1.subscriptions.count
        sut1.cancelLoading()
        let count1After = cancelBag1.subscriptions.count
        let errorSet = sut1.error != nil
        var sut2 = Loadable<Int>.isLoading(last: 7, cancelBag: cancelBag2)
        sut2.cancelLoading()
        let value2 = sut2.value ?? -1
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("count1Before")?.stringified == "1")
        #expect(interpreter.globals.lookup("count1After")?.stringified == "0")
        #expect(interpreter.globals.lookup("errorSet")?.stringified == "true")
        #expect(interpreter.globals.lookup("value2")?.stringified == "7")
    }
}

@Suite struct AliasedRangeStaticDefaultTests {
    // clean-architecture's `httpCodes: HTTPCodes = .success` default, where
    // `typealias HTTPCodes = Range<HTTPCode>` and the static lives in
    // `extension HTTPCodes`. The extension collects under the canonical
    // head "Range"; annotation resolution must canonicalize the same way.
    @Test func staticDefaultResolvesThroughAlias() throws {
        let source = """
        typealias HTTPCode = Int
        typealias HTTPCodes = Range<HTTPCode>
        extension HTTPCodes {
            static let success = 200 ..< 300
        }
        func check(codes: HTTPCodes = .success) -> Bool {
            codes.contains(250)
        }
        let ok = check()
        let range = "\\(HTTPCodes.success)"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("ok")?.stringified == "true")
        #expect(interpreter.globals.lookup("range")?.stringified == "200..<300")
    }
}

@Suite struct WebRepositoryMockPipelineTests {
    // clean-architecture's CountriesWebRepositoryTests genre, END TO END:
    // URLProtocol subclass + NSLock static store + `URLSession
    // .mockedResponsesOnly` (a static computed property on a HOST-type
    // extension) + async `session.data(for:)` + JSONEncoder/Decoder round
    // trip. Native swiftc scratch run: roundTripped == true.
    @Test func mockedSessionServesEncodedFixture() throws {
        let source = """
        import Foundation
        import Combine

        struct Payload: Codable, Equatable {
            let name: String
            let number: Int
        }

        struct MockedResponse {
            let url: URL
            let data: Data
            init<T: Encodable>(url: URL, value: T) throws {
                self.url = url
                self.data = try JSONEncoder().encode(value)
            }
        }

        extension RequestMocking {
            private final class MocksContainer: @unchecked Sendable {
                var mocks: [MockedResponse] = []
            }
            static private let container = MocksContainer()
            static private let lock = NSLock()
            static func add(mock: MockedResponse) {
                lock.withLock { container.mocks.append(mock) }
            }
            static private func mock(for request: URLRequest) -> MockedResponse? {
                return lock.withLock { container.mocks.first { $0.url == request.url } }
            }
        }

        final class RequestMocking: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                return mock(for: request) != nil
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                if let mock = RequestMocking.mock(for: request),
                   let url = request.url,
                   let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: mock.data)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() { }
        }

        extension URLSession {
            static var mockedResponsesOnly: URLSession {
                let configuration = URLSessionConfiguration.default
                configuration.protocolClasses = [RequestMocking.self]
                configuration.timeoutIntervalForRequest = 1
                return URLSession(configuration: configuration)
            }
        }

        typealias HTTPCode = Int
        typealias HTTPCodes = Range<HTTPCode>
        extension HTTPCodes {
            static let success = 200 ..< 300
        }
        protocol WebRepository {
            var session: URLSession { get }
            var baseURL: String { get }
        }
        extension WebRepository {
            func call<Value, Decoder>(
                path: String,
                decoder: Decoder = JSONDecoder(),
                httpCodes: HTTPCodes = .success
            ) async throws -> Value
            where Value: Decodable, Decoder: TopLevelDecoder, Decoder.Input == Data {
                let request = URLRequest(url: URL(string: baseURL + path)!)
                let (data, response) = try await session.data(for: request)
                guard let code = (response as? HTTPURLResponse)?.statusCode else {
                    throw NSError(domain: "unexpectedResponse", code: 0)
                }
                guard httpCodes.contains(code) else {
                    throw NSError(domain: "httpCode", code: 0)
                }
                return try decoder.decode(Value.self, from: data)
            }
        }
        struct Repo: WebRepository {
            let session: URLSession
            let baseURL: String
            func load() async throws -> [Payload] {
                try await call(path: "/items")
            }
        }

        let sut = Repo(session: .mockedResponsesOnly, baseURL: "https://test.example")
        let expected = [Payload(name: "one", number: 1), Payload(name: "two", number: 2)]
        try RequestMocking.add(mock: MockedResponse(url: URL(string: "https://test.example/items")!, value: expected))
        var roundTripped = false
        var count = 0
        var thrownDomain = ""
        do {
            let items = try await sut.load()
            roundTripped = items == expected
            count = items.count
        } catch {
            thrownDomain = "\\(error)"
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("thrownDomain")?.stringified == "")
        #expect(interpreter.globals.lookup("roundTripped")?.stringified == "true")
        #expect(interpreter.globals.lookup("count")?.stringified == "2")
    }

    // The SAME pipeline through the harness: a final-class @Suite holding
    // `private let sut = Repo(session: .mockedResponsesOnly)` — the stored
    // property's ctor call resolves the implicit member against the
    // DECLARED init's parameter annotation.
    @Test func suiteStoredPropertySessionResolves() throws {
        let source = """
        import Foundation
        import Combine
        import Testing

        struct Payload: Codable, Equatable {
            let name: String
        }

        struct MockedResponse {
            let url: URL
            let data: Data
            init<T: Encodable>(url: URL, value: T) throws {
                self.url = url
                self.data = try JSONEncoder().encode(value)
            }
        }

        extension RequestMocking {
            private final class MocksContainer: @unchecked Sendable {
                var mocks: [MockedResponse] = []
            }
            static private let container = MocksContainer()
            static private let lock = NSLock()
            static func add(mock: MockedResponse) {
                lock.withLock { container.mocks.append(mock) }
            }
            static func removeAllMocks() {
                lock.withLock { container.mocks.removeAll() }
            }
            static private func mock(for request: URLRequest) -> MockedResponse? {
                return lock.withLock { container.mocks.first { $0.url == request.url } }
            }
        }

        final class RequestMocking: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool {
                return mock(for: request) != nil
            }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                if let mock = RequestMocking.mock(for: request),
                   let url = request.url,
                   let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: mock.data)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
            override func stopLoading() { }
        }

        extension URLSession {
            static var mockedResponsesOnly: URLSession {
                let configuration = URLSessionConfiguration.default
                configuration.protocolClasses = [RequestMocking.self]
                return URLSession(configuration: configuration)
            }
        }

        protocol WebRepository {
            var session: URLSession { get }
            var baseURL: String { get }
        }
        extension WebRepository {
            func call<Value>(path: String) async throws -> Value where Value: Decodable {
                let request = URLRequest(url: URL(string: baseURL + path)!)
                let (data, response) = try await session.data(for: request)
                guard let code = (response as? HTTPURLResponse)?.statusCode, code == 200 else {
                    throw NSError(domain: "http", code: 1)
                }
                return try JSONDecoder().decode(Value.self, from: data)
            }
        }

        protocol ItemsWebRepository: WebRepository {
            func load() async throws -> [Payload]
        }

        struct Repo: ItemsWebRepository {
            let session: URLSession
            let baseURL: String
            init(session: URLSession) {
                self.session = session
                self.baseURL = "https://real.example/v2"
            }
            func load() async throws -> [Payload] {
                return try await call(path: "/items")
            }
        }

        @Suite(.serialized) final class RepoTests {
            private let sut = Repo(session: .mockedResponsesOnly)

            deinit {
                RequestMocking.removeAllMocks()
            }

            @Test func loadsMockedPayloads() async throws {
                let expected = [Payload(name: "one")]
                try RequestMocking.add(mock: MockedResponse(url: URL(string: "https://real.example/v2/items")!, value: expected))
                let response = try await sut.load()
                #expect(response == expected)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.passed == 1)
        #expect(report.failed == 0)
        #expect(report.errored == 0)
    }
}

@Suite struct DottedExtensionInitTests {
    // RequestMocking.MockedResponse: the throwing custom init lives in a
    // DOTTED extension of the nested struct — instantiation must run it.
    @Test func dottedExtensionInitRuns() throws {
        let source = """
        final class RequestMocking {}
        extension RequestMocking {
            struct MockedResponse {
                let url: URL
                let payload: String
            }
        }
        extension RequestMocking.MockedResponse {
            init(apiCall: String, baseURL: String) throws {
                guard let url = URL(string: baseURL + apiCall) else {
                    fatalError("bad url")
                }
                self.url = url
                self.payload = "made"
            }
        }
        let mock = try RequestMocking.MockedResponse(apiCall: "/x", baseURL: "https://t.co")
        let madeURL = mock.url.absoluteString
        let payload = mock.payload
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("madeURL")?.stringified == "https://t.co/x")
        #expect(interpreter.globals.lookup("payload")?.stringified == "made")
    }
}

@Suite struct DelayedAsyncAfterTests {
    // RequestMocking's startLoading delivers through
    // DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) — bounded
    // delays run once per drain (never spin like self-rescheduling
    // retries).
    @Test func boundedDelayDeliversOnDrain() throws {
        // A rendering test may have flipped the demo's wall-clock mode on
        // (a global): probes drain.
        let previous = MainQueueDrain.schedulesRealTimers
        MainQueueDrain.schedulesRealTimers = false
        defer { MainQueueDrain.schedulesRealTimers = previous }
        let source = """
        final class Recorder {
            var fired = false
        }
        let recorder = Recorder()
        let loadingTime: TimeInterval = 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + loadingTime) { [weak recorder] in
            guard let recorder else { return }
            recorder.fired = true
        }
        let before = recorder.fired
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("before")?.stringified == "false")
        MainQueueDrain.drain()
        let recorder = interpreter.globals.lookup("recorder")
        guard case .instance(let instance)? = recorder else {
            Issue.record("recorder missing")
            return
        }
        #expect(instance.box(for: "fired")?.value.stringified == "true")
    }
}

@Suite struct GenericCallDecodeTests {
    // clean-architecture's WebRepository.call<Value: Decodable>: the
    // decode runs INSIDE the generic body (`decoder.decode(Value.self,
    // from: data)`) — natively Value pins from the CALLER's typed let.
    @Test func typedLetPinsGenericDecode() throws {
        let source = """
        struct CountryDetails: Codable, Equatable {
            let capital: String
        }
        enum APIError: Swift.Error {
            case unexpectedResponse
        }
        struct Repo {
            func call<Value>(json: String) throws -> Value where Value: Decodable {
                let decoder = JSONDecoder()
                let data = json.data(using: .utf8)!
                do {
                    return try decoder.decode(Value.self, from: data)
                } catch {
                    throw APIError.unexpectedResponse
                }
            }
            func details() throws -> CountryDetails {
                let response: [CountryDetails] = try call(json: #"[{"capital": "London"}]"#)
                guard let details = response.first else {
                    throw APIError.unexpectedResponse
                }
                return details
            }
            func emptyDetails() throws -> CountryDetails {
                let response: [CountryDetails] = try call(json: "[]")
                guard let details = response.first else {
                    throw APIError.unexpectedResponse
                }
                return details
            }
        }
        let repo = Repo()
        let capital = (try? repo.details())?.capital ?? "NONE"
        var threw = false
        do {
            _ = try repo.emptyDetails()
        } catch {
            threw = true
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("capital")?.stringified == "London")
        #expect(interpreter.globals.lookup("threw")?.stringified == "true")
    }
}

@Suite struct AsyncGenericCallDecodeTests {
    // The REAL shape: async throws, TWO generic params (Decoder defaulted
    // to JSONDecoder()), the caller pinning Value through `try await`.
    @Test func awaitWrappedTypedLetPinsGenericDecode() throws {
        let source = """
        struct CountryDetails: Codable, Equatable {
            let capital: String
        }
        enum APIError: Swift.Error {
            case unexpectedResponse
        }
        protocol WebRepositoryProto {}
        extension WebRepositoryProto {
            func call<Value, Decoder>(
                json: String,
                decoder: Decoder = JSONDecoder()
            ) async throws -> Value
            where Value: Decodable, Decoder: TopLevelDecoder, Decoder.Input == Data {
                let data = json.data(using: .utf8)!
                do {
                    return try decoder.decode(Value.self, from: data)
                } catch {
                    throw APIError.unexpectedResponse
                }
            }
        }
        struct Repo: WebRepositoryProto {
            func details() async throws -> CountryDetails {
                let response: [CountryDetails] = try await call(json: #"[{"capital": "London"}]"#)
                guard let details = response.first else {
                    throw APIError.unexpectedResponse
                }
                return details
            }
            func emptyDetails() async throws -> CountryDetails {
                let response: [CountryDetails] = try await call(json: "[]")
                guard let details = response.first else {
                    throw APIError.unexpectedResponse
                }
                return details
            }
        }
        let repo = Repo()
        var capital = "NONE"
        var threw = false
        Task {
            capital = (try? await repo.details())?.capital ?? "NONE"
            do {
                _ = try await repo.emptyDetails()
            } catch {
                threw = true
            }
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("capital")?.stringified == "London")
        #expect(interpreter.globals.lookup("threw")?.stringified == "true")
    }
}

@Suite struct InheritedInitializerTests {
    // The test-suite subclass pattern: `@Suite class Base { init() {…} }`
    // + `final class CaseTests: Base` — a class with NO initializers
    // inherits its superclass's designated init (self = the subclass).
    @Test func subclassRunsInheritedDesignatedInit() throws {
        let source = """
        class MockRepo {
            var responses: [String] = []
        }
        class BaseTests {
            let mock: MockRepo
            let label: String
            init() {
                mock = MockRepo()
                mock.responses = ["seeded"]
                label = "ready"
            }
        }
        final class CaseTests: BaseTests {
            func probe() -> String {
                label + ":" + (mock.responses.first ?? "empty")
            }
        }
        let probed = CaseTests().probe()
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("probed")?.stringified == "ready:seeded")
    }
}

@Suite struct ResultValueSemanticsTests {
    // clean-architecture's mock plumbing: `[Result<T, Error>]` arrays of
    // implicit `.success`/`.failure`, drained by `removeFirst().get()`,
    // matched by `case .success` patterns. Void success (`.success(())`)
    // rides too.
    @Test func annotatedResultsGetAndMatch() throws {
        let source = """
        struct Item: Equatable {
            let name: String
        }
        enum MockError: Swift.Error {
            case valueNotSet
        }
        final class MockStore {
            var responses: [Result<[Item], Error>] = []
            var storeResults: [Result<Void, Error>] = []
            func fetch() throws -> [Item] {
                guard !responses.isEmpty else { throw MockError.valueNotSet }
                return try responses.removeFirst().get()
            }
            func store() throws {
                guard !storeResults.isEmpty else { throw MockError.valueNotSet }
                try storeResults.removeFirst().get()
            }
        }
        struct TestError: Swift.Error, Equatable {
            let code: Int
        }
        let store = MockStore()
        store.responses = [.success([Item(name: "a")]), .failure(TestError(code: 7))]
        store.storeResults = [.success(())]
        let first = (try? store.fetch())?.first?.name ?? "NONE"
        var caught = TestError(code: 0)
        do {
            _ = try store.fetch()
        } catch let error as TestError {
            caught = error
        } catch {}
        var stored = false
        do {
            try store.store()
            stored = true
        } catch {}
        let describedResult: Result<[Item], Error> = .success([Item(name: "b")])
        var matched = "none"
        switch describedResult {
        case let .success(items):
            matched = items.first?.name ?? "empty"
        case .failure:
            matched = "failure"
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("first")?.stringified == "a")
        #expect(interpreter.globals.lookup("caught")?.stringified.contains("7") == true)
        #expect(interpreter.globals.lookup("stored")?.stringified == "true")
        #expect(interpreter.globals.lookup("matched")?.stringified == "b")
    }
}

@Suite struct DrainIsolationTests {
    // One program's queued deliveries must never fire inside the next
    // verification (corpus determinism).
    @Test func resetClearsQueuedDeliveries() throws {
        let previous = MainQueueDrain.schedulesRealTimers
        MainQueueDrain.schedulesRealTimers = false
        defer { MainQueueDrain.schedulesRealTimers = previous }
        let source = """
        final class Recorder {
            var fired = false
        }
        let recorder = Recorder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            recorder.fired = true
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        HeadlessVerifier.resetBridgeEnvironment()
        MainQueueDrain.drain()
        guard case .instance(let instance)? = interpreter.globals.lookup("recorder") else {
            Issue.record("recorder missing")
            return
        }
        #expect(instance.box(for: "fired")?.value.stringified == "false")
    }
}

@Suite struct DeclaredComparableGatewayTests {
    // Milestones' genre: XCTAssertLessThan over a type whose Comparable
    // is a declared `static func <` comparing TUPLES lexicographically —
    // the gateway must dispatch the declared operator like infix does.
    // Native (verified 2026-07-11): A<B true, B<A false, earlier date wins.
    @Test func gatewayDispatchesDeclaredLessThan() throws {
        let source = """
        import XCTest

        struct Milestone: Equatable, Comparable {
            var title: String
            var date: Date

            static func < (lhs: Milestone, rhs: Milestone) -> Bool {
                (lhs.date, lhs.title) < (rhs.date, rhs.title)
            }
        }

        final class ComparableTests: XCTestCase {
            func testTitleOrders() {
                let a = Milestone(title: "A", date: Date(timeIntervalSinceReferenceDate: 604800))
                let b = Milestone(title: "B", date: Date(timeIntervalSinceReferenceDate: 604800))
                XCTAssertLessThan(a, b)
                XCTAssertGreaterThan(b, a)
            }
            func testDateOrdersFirst() {
                let late = Milestone(title: "A", date: Date(timeIntervalSinceReferenceDate: 604800))
                let early = Milestone(title: "Z", date: Date(timeIntervalSinceReferenceDate: 0))
                XCTAssertLessThan(early, late)
                XCTAssertLessThanOrEqual(early, early)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.passed == 2)
        #expect(report.failed == 0)
        #expect(report.errored == 0)
    }
}

@Suite struct BindingExtensionMethodTests {
    // clean-architecture's LoadableTests: a hand-built
    // Binding<Loadable<String>>.init(get:set:) receiving an app
    // extension method (`extension Binding { func load }`) that writes
    // through wrappedValue.
    @Test func extensionMethodDispatchesOnBuiltBinding() throws {
        let source = """
        enum Loadable<T> {
            case notRequested
            case loaded(T)
        }
        typealias LoadableSubject<T> = Binding<Loadable<T>>
        extension LoadableSubject {
            func setLoaded<T>(_ value: T) where Value == Loadable<T> {
                wrappedValue = .loaded(value)
            }
        }
        var values: [Loadable<String>] = []
        let sut = Binding<Loadable<String>>.init(get: {
            return values.last ?? .notRequested
        }, set: {
            values.append($0)
        })
        sut.setLoaded("test")
        let count = values.count
        var loadedText = "NONE"
        if case let .loaded(text) = values.last ?? .notRequested {
            loadedText = text
        }
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("count")?.stringified == "1")
        #expect(interpreter.globals.lookup("loadedText")?.stringified == "test")
    }
}

@Suite struct CurrentValueSubjectStoreTests {
    // clean-architecture's Store: `typealias Store<State> =
    // CurrentValueSubject<State, Never>` + an extension subscript taking
    // a WritableKeyPath with a SETTER that copies value, compares, and
    // publishes. Reads and writes must round-trip the real state.
    @Test func keyPathSubscriptWritesThroughStore() throws {
        let source = """
        import Combine

        struct Permissions: Equatable {
            var push: String = "unknown"
        }
        struct AppState: Equatable {
            var permissions = Permissions()
            var count: Int = 0
        }
        typealias Store<State> = CurrentValueSubject<State, Never>

        extension Store {
            subscript<T>(keyPath: WritableKeyPath<Output, T>) -> T where T: Equatable {
                get { value[keyPath: keyPath] }
                set {
                    var value = self.value
                    if value[keyPath: keyPath] != newValue {
                        value[keyPath: keyPath] = newValue
                        self.value = value
                    }
                }
            }
        }

        let appState = Store<AppState>(AppState())
        appState[\\.permissions.push] = "granted"
        appState[\\.count] = 7
        let push = appState.value.permissions.push
        let count = appState.value.count
        let viaSubscript = appState[\\.permissions.push]
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("push")?.stringified == "granted")
        #expect(interpreter.globals.lookup("count")?.stringified == "7")
        #expect(interpreter.globals.lookup("viaSubscript")?.stringified == "granted")
    }
}

@Suite struct ComposableArchitectureShimTests {
    // Milestones' genre: old-TCA Reducer/TestStore over the distilled
    // shim — sends reduce, fireAndForget persists, forEach routes
    // case-path element actions, variadic Steps resolve implicit members.
    @Test func reducerTestStorePersistsAndRoutes() throws {
        let source = """
        import ComposableArchitecture

        struct Item: Equatable {
            var title: String
        }
        struct AppState: Equatable {
            var items: [Item]
        }
        enum ItemAction: Equatable {
            case rename(String)
        }
        enum AppAction: Equatable {
            case removeFirst
            case item(index: Int, action: ItemAction)
            case persistToDisk
        }
        struct AppEnvironment {
            let persist: ([Item]) -> Void
        }

        let itemReducer = Reducer<Item, ItemAction, Void> { state, action, _ in
            switch action {
            case .rename(let title):
                state.title = title
                return .none
            }
        }

        let appReducer = Reducer<AppState, AppAction, AppEnvironment>.combine(
            itemReducer.forEach(
                state: \\AppState.items,
                action: /AppAction.item,
                environment: { _ in () }
            ),
            Reducer { state, action, environment in
                switch action {
                case .removeFirst:
                    state.items.remove(atOffsets: [0])
                    return .none
                case .item:
                    return .none
                case .persistToDisk:
                    return Effect.fireAndForget { environment.persist(state.items) }
                }
            }
        )

        var persisted = [[Item]]()
        let store = TestStore(
            initialState: AppState(items: [Item(title: "a"), Item(title: "b")]),
            reducer: appReducer,
            environment: AppEnvironment(persist: { persisted.append($0) })
        )
        store.assert(
            .send(.item(index: 1, action: .rename("B"))) { _ in },
            .send(.removeFirst) { _ in },
            .send(.persistToDisk)
        )
        let persistedCount = persisted.count
        let firstTitle = persisted.first?.first?.title ?? "NONE"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source + "\n"
            + LibraryShims.shims(importedIn: ["ComposableArchitecture"], mergedSource: ""))
        #expect(interpreter.globals.lookup("persistedCount")?.stringified == "1")
        #expect(interpreter.globals.lookup("firstTitle")?.stringified == "B")
    }
}

@Suite struct ChainedStoreSubscriptTests {
    // DeepLinksHandler's shape: the store reached through a CONTAINER
    // property chain (`self.container.appState[\\.routing] = x`), under
    // the harness registry.
    @Test func chainedBaseSubscriptWritesThroughSetter() throws {
        let source = """
        import XCTest
        import Combine

        struct Routing: Equatable {
            var countryCode: String? = nil
        }
        struct AppState: Equatable {
            var routing = Routing()
        }
        typealias Store<State> = CurrentValueSubject<State, Never>

        extension Store {
            subscript<T>(keyPath: WritableKeyPath<Output, T>) -> T where T: Equatable {
                get { value[keyPath: keyPath] }
                set {
                    var value = self.value
                    if value[keyPath: keyPath] != newValue {
                        value[keyPath: keyPath] = newValue
                        self.value = value
                    }
                }
            }
        }

        struct DIContainer {
            let appState: Store<AppState>
        }

        final class Handler {
            let container: DIContainer
            init(container: DIContainer) {
                self.container = container
            }
            func reset() {
                var routing = Routing()
                routing.countryCode = "US"
                self.container.appState[\\.routing] = routing
            }
        }

        final class DeepLinkTests: XCTestCase {
            func testRoutingWrite() {
                let container = DIContainer(appState: Store<AppState>(AppState()))
                let handler = Handler(container: container)
                handler.reset()
                XCTAssertEqual(container.appState.value.routing.countryCode, "US")
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.passed == 1)
        #expect(report.failed == 0)
        #expect(report.errored == 0)
    }
}

@Suite struct LoadableTransitionHistoryTests {
    // ImagesInteractor's genre: a history-recording Binding receives
    // setIsLoading (a mutating enum method that REASSIGNS self, written
    // back through the binding) and then a Task-delivered .loaded.
    @Test func transitionsRecordThroughBinding() throws {
        let source = """
        enum Loadable<T>: Equatable {
            static func == (lhs: Loadable<T>, rhs: Loadable<T>) -> Bool {
                switch (lhs, rhs) {
                case (.notRequested, .notRequested): return true
                case (.isLoading, .isLoading): return true
                case let (.loaded(a), .loaded(b)): return "\\(a)" == "\\(b)"
                default: return false
                }
            }
            case notRequested
            case isLoading(last: T?)
            case loaded(T)

            mutating func setIsLoading() {
                self = .isLoading(last: value)
            }

            var value: T? {
                if case let .loaded(value) = self { return value }
                return nil
            }
        }

        final class BindingWithHistory<Value> {
            private(set) var binding: Binding<Value>
            private(set) var history: [Value]

            init(value: Value) {
                binding = .constant(value)
                history = [value]
                var value = value
                binding = Binding<Value>(get: {
                    value
                }, set: { [weak self] in
                    value = $0
                    self?.history.append($0)
                })
            }
        }

        extension Binding {
            func load<T>(_ resource: @escaping () async throws -> T) where Value == Loadable<T> {
                wrappedValue.setIsLoading()
                let task = Task {
                    do {
                        wrappedValue = .loaded(try await resource())
                    } catch {
                        wrappedValue = .notRequested
                    }
                }
                _ = task
            }
        }

        let state = BindingWithHistory(value: Loadable<String>.notRequested)
        state.binding.load {
            return "IMAGE"
        }
        let count = state.history.count
        var shape = [String]()
        for entry in state.history {
            switch entry {
            case .notRequested: shape.append("notRequested")
            case .isLoading: shape.append("isLoading")
            case .loaded: shape.append("loaded")
            }
        }
        let joined = shape.joined(separator: ",")
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        MainQueueDrain.drain()
        #expect(interpreter.globals.lookup("joined")?.stringified == "notRequested,isLoading,loaded")
    }
}

@Suite struct SwiftDataStoreTests {
    // clean-architecture's DB genre: a @ModelActor repository over an
    // in-memory ModelContainer — insert in a transaction, fetch by
    // FetchDescriptor (bare-generic and #Predicate forms).
    @Test func modelContextRoundTrips() throws {
        let source = """
        import SwiftData

        enum DBModel {}

        extension DBModel {
            @Model final class Country {
                var name: String
                var alpha3Code: String
                init(name: String, alpha3Code: String) {
                    self.name = name
                    self.alpha3Code = alpha3Code
                }
            }
        }

        @ModelActor
        final actor MainDBRepository { }

        extension MainDBRepository {
            func store(names: [(String, String)]) throws {
                try modelContext.transaction {
                    for entry in names {
                        modelContext.insert(DBModel.Country(name: entry.0, alpha3Code: entry.1))
                    }
                }
            }
            func country(alpha3Code: String) throws -> DBModel.Country? {
                let code = alpha3Code
                let descriptor = FetchDescriptor(predicate: #Predicate<DBModel.Country> {
                    $0.alpha3Code == code
                })
                return try modelContainer.mainContext.fetch(descriptor).first
            }
        }

        let container = ModelContainer()
        let sut = MainDBRepository(modelContainer: container)
        try sut.store(names: [("France", "FRA"), ("Italy", "ITA")])
        let all = try container.mainContext.fetch(FetchDescriptor<DBModel.Country>())
        let total = all.count
        let italy = try sut.country(alpha3Code: "ITA")
        let italyName = italy?.name ?? "NONE"
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("total")?.stringified == "2")
        #expect(interpreter.globals.lookup("italyName")?.stringified == "Italy")
    }

    // MinimalTodo/Meshtastic shape: `var descriptor = FetchDescriptor<T>()`
    // then mutating `fetchLimit`/`sortBy` before fetching.
    @Test func mutableDescriptorConfig() throws {
        let source = """
        import SwiftData

        @Model final class Task {
            var title: String
            init(title: String) { self.title = title }
        }

        let container = ModelContainer()
        let context = container.mainContext
        context.insert(Task(title: "a"))
        context.insert(Task(title: "b"))
        context.insert(Task(title: "c"))
        var descriptor = FetchDescriptor<Task>()
        descriptor.fetchLimit = 2
        descriptor.sortBy = [SortDescriptor(\\.title)]
        let limited = try context.fetch(descriptor).count
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("limited")?.stringified == "2")
    }
}

@Suite struct StructEqualitySynthesisTests {
    // clean-architecture's AppState genre: `state.value == AppState()` —
    // struct equality must be member-wise (Equatable synthesis), honor a
    // TOP-LEVEL `func ==`, and recurse through nested structs, enums and
    // arrays. Native run (scratch swiftc): all four flags are true.
    @Test func memberwiseAndTopLevelOperator() throws {
        let source = """
        import SwiftUI

        struct AppState: Equatable {
            var routing = ViewRouting()
            var system = System()
            var permissions = Permissions()
        }
        extension AppState {
            struct ViewRouting: Equatable {
                var countriesList = ListRouting()
            }
            struct System: Equatable {
                var isActive: Bool = false
                var keyboardHeight: CGFloat = 0
            }
            struct Permissions: Equatable {
                var push: Permission.Status = .unknown
            }
        }
        struct ListRouting: Equatable { var countryCode: String? }
        enum Permission {
            case pushNotifications
            enum Status: Equatable { case unknown, notRequested, granted, denied }
        }
        func == (lhs: AppState, rhs: AppState) -> Bool {
            lhs.routing == rhs.routing && lhs.system == rhs.system && lhs.permissions == rhs.permissions
        }

        let freshEqual = AppState() == AppState()
        var mutated = AppState()
        mutated.permissions.push = .granted
        let mutatedDiffers = mutated != AppState()
        var reverted = mutated
        reverted.permissions.push = .unknown
        let revertedEqual = reverted == AppState()

        struct Country: Equatable { var name: String; var alpha3Code: String }
        let countriesEqual = [Country(name: "France", alpha3Code: "FRA")] == [Country(name: "France", alpha3Code: "FRA")]
        """
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("freshEqual")?.stringified == "true")
        #expect(interpreter.globals.lookup("mutatedDiffers")?.stringified == "true")
        #expect(interpreter.globals.lookup("revertedEqual")?.stringified == "true")
        #expect(interpreter.globals.lookup("countriesEqual")?.stringified == "true")
    }
}
