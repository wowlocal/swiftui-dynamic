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
