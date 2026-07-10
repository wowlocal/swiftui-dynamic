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
