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
