import Testing
import SwiftInterpreter
import SwiftUIBridge

/// The icecubes Client-actor class: actor methods must EXECUTE
/// (inline-async semantics) so `.task` fetches land.
@Suite struct ActorExecutionTests {
    @Test func actorMethodExecutes() throws {
        let source = """
        actor Client {
            var calls = 0
            func fetch(path: String) async throws -> [String] {
                calls += 1
                return ["a:\\(path)", "b:\\(path)"]
            }
        }
        let client = Client()
        var got: [String] = []
        func load() async {
            let items = try? await client.fetch(path: "/timeline")
            got = items ?? []
        }
        await load()
        got.joined(separator: ",")
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "a:/timeline,b:/timeline")
    }

    @Test func actorStateMutatesAcrossCalls() throws {
        let source = """
        actor Counter {
            var value = 0
            func bump() async -> Int {
                value += 1
                return value
            }
        }
        let counter = Counter()
        var seen: [Int] = []
        func drive() async {
            seen.append(await counter.bump())
            seen.append(await counter.bump())
        }
        await drive()
        seen
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringified == "[1, 2]")
    }
}
