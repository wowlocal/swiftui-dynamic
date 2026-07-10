import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The inline Combine spine: publishers ARE their computed outcome —
/// the ACHNBrowserUI ItemsAPI genre end to end.
@Suite struct CombineSpineTests {
    @Test func resultPublisherChainDeliversDecodedItems() throws {
        let directory = NSTemporaryDirectory() + "combine-spine-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let json = #"{"total": 2, "results": [{"name": "Snapping turtle"}, {"name": "Sea bass"}]}"#
        try json.write(toFile: directory + "/fish", atomically: true, encoding: .utf8)
        BundleResources.roots = [directory]
        defer { BundleResources.roots = [] }

        let source = """
        struct ItemRow: Codable {
            let name: String
        }
        struct ItemResponse: Codable {
            let total: Int
            let results: [ItemRow]

            init(total: Int, results: [ItemRow]) {
                self.total = total
                self.results = results
            }
        }
        struct API {
            static let decoder = JSONDecoder()
            static func fetchFile<T: Codable>(name: String) -> AnyPublisher<T, APIError> {
                Result(catching: {
                    guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                        throw APIError.message(reason: "missing")
                    }
                    return try Data(contentsOf: url)
                })
                .publisher
                .decode(type: T.self, decoder: Self.decoder)
                .mapError { APIError.message(reason: "\\(($0))") }
                .subscribe(on: DispatchQueue.main)
                .eraseToAnyPublisher()
            }
        }
        enum APIError: Error {
            case message(reason: String)
        }
        var names: [String] = []
        _ = API.fetchFile(name: "fish")
            .replaceError(with: ItemResponse(total: 0, results: []))
            .eraseToAnyPublisher()
            .map { $0.results }
            .subscribe(on: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { items in
                names = items.map { $0.name }
            }
        names.joined(separator: ",")
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "Snapping turtle,Sea bass")
    }

    @Test func dataTaskPublisherServesFixtures() throws {
        let directory = NSTemporaryDirectory() + "combine-dtp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try #"[{"title": "hello"}]"#.write(toFile: directory + "/news.json", atomically: true, encoding: .utf8)
        NetworkBridge.policy = .replay(fixturesDirectory: directory)
        defer { NetworkBridge.policy = .absorbed }

        let source = """
        struct Article: Codable {
            let title: String
        }
        var titles: [String] = []
        let decoder = JSONDecoder()
        _ = URLSession.shared.dataTaskPublisher(for: URL(string: "https://api.example.com/news")!)
            .map(\\.data)
            .decode(type: [Article].self, decoder: decoder)
            .replaceError(with: [])
            .sink { articles in
                titles = articles.map { $0.title }
            }
        titles.joined(separator: ",")
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "hello")
    }
}
