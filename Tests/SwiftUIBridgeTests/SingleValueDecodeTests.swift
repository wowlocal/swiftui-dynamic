import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The HTMLString genre (IceCubes): a custom-Codable type whose declared
/// `init(from:)` reads a singleValueContainer SCALAR must decode through
/// that init — structural decode only fits object-backed types.
@Suite struct SingleValueDecodeTests {
    private static func withFixture(_ json: String, _ run: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-value-decode-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try json.write(toFile: directory + "/payload.json", atomically: true, encoding: .utf8)
        try run(directory)
    }

    @Test func scalarStringRunsCustomInit() throws {
        try Self.withFixture(#"[{"id": "1", "content": "<p>hello</p>"}, {"id": "2", "content": "<p>world</p>"}]"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct HTMLString: Codable {
                var htmlValue: String = ""
                var asRawText: String = ""
                init(from decoder: Decoder) throws {
                    do {
                        let container = try decoder.singleValueContainer()
                        htmlValue = try container.decode(String.self)
                    } catch {
                        htmlValue = ""
                    }
                    asRawText = htmlValue.uppercased()
                }
            }
            struct Status: Codable {
                let id: String
                let content: HTMLString
            }
            let statuses = try JSONDecoder().decode([Status].self, from: __fixtureData("payload"))
            statuses.map { $0.content.asRawText }.joined(separator: " ")
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "<P>HELLO</P> <P>WORLD</P>")
        }
    }

    @Test func scalarNumberRunsCustomInit() throws {
        try Self.withFixture(#"{"name": "pin", "weight": 12.5}"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Grams: Codable {
                var value: Double = 0
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    value = try container.decode(Double.self)
                }
            }
            struct Item: Codable {
                let name: String
                let weight: Grams
            }
            let item = try JSONDecoder().decode(Item.self, from: __fixtureData("payload"))
            "\\(item.name) \\(item.weight.value)"
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "pin 12.5")
        }
    }

    @Test func keyedCustomInitComputesCacheFields() throws {
        // The Account genre: explicit CodingKeys OMIT a stored property the
        // declared init(from:) computes — only running the real init decodes.
        try Self.withFixture(#"{"id": "7", "display_name": "", "username": "ada", "followers_count": 3}"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Account: Codable {
                let id: String
                let username: String
                let displayName: String?
                let followersCount: Int?
                let cachedDisplayName: String

                enum CodingKeys: CodingKey {
                    case id
                    case username
                    case displayName
                    case followersCount
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    id = try container.decode(String.self, forKey: .id)
                    username = try container.decode(String.self, forKey: .username)
                    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                    followersCount = try container.decodeIfPresent(Int.self, forKey: .followersCount)
                    if let displayName, !displayName.isEmpty {
                        cachedDisplayName = displayName
                    } else {
                        cachedDisplayName = "@\\(username)"
                    }
                }
            }
            let account = try JSONDecoder().decode(Account.self, from: __fixtureData("payload"))
            "\\(account.cachedDisplayName) \\(account.followersCount ?? 0)"
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "@ada 3")
        }
    }

    @Test func uuidFieldsRoundTripLikeFoundationCodable() throws {
        try Self.withFixture(
            #"{"id": "abcdefab-cdef-abcd-efab-cdefabcdefab"}"#
        ) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Payload: Codable {
                let id: UUID
                let lock = NSLock()

                enum CodingKeys: CodingKey {
                    case id
                }
            }
            let key = Payload.CodingKeys.id.stringValue
            let payload = try JSONDecoder().decode(
                Payload.self, from: __fixtureData("payload"))
            let encoded = try JSONEncoder().encode(payload)
            let object = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
            let encodedKeys = object.allKeys.compactMap { $0 as? String }.joined(separator: ",")
            let equalCopy = object.isEqual(
                try JSONSerialization.jsonObject(with: encoded) as! NSDictionary)
            let roundTripped = try JSONDecoder().decode(
                Payload.self, from: encoded)
            "\\(key)|\\(payload.id.uuidString)|\\(roundTripped.id.uuidString)|\\(encodedKeys)|\\(equalCopy)"
            """
            let result = try Interpreter(registry: ViewRegistry()).run(
                source: source)
            #expect(result.stringValue ==
                "id|ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB|"
                    + "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB|id|true")
        }
    }

    @Test func defaultDateDecodesReferenceDateSeconds() throws {
        try Self.withFixture(#"{"created": 700000000.0}"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Payload: Codable {
                let created: Date
            }
            let payload = try JSONDecoder().decode(
                Payload.self, from: __fixtureData("payload"))
            payload.created.timeIntervalSinceReferenceDate
            """
            let result = try Interpreter(registry: ViewRegistry()).run(
                source: source)
            #expect(result.doubleValue == 700_000_000)
        }
    }

    @Test func objectBackedTypesStillDecodeStructurally() throws {
        try Self.withFixture(#"{"tag": {"label": "swift"}}"#) { directory in
            NetworkBridge.policy = .replay(fixturesDirectory: directory)
            defer { NetworkBridge.policy = .absorbed }
            let source = """
            struct Tag: Codable {
                let label: String
            }
            struct Post: Codable {
                let tag: Tag
            }
            let post = try JSONDecoder().decode(Post.self, from: __fixtureData("payload"))
            post.tag.label
            """
            let result = try Interpreter(registry: ViewRegistry()).run(source: source)
            #expect(result.stringValue == "swift")
        }
    }
}
