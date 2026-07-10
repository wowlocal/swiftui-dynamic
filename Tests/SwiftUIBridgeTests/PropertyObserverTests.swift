import Testing
import SwiftInterpreter
import SwiftUIBridge

/// Property observers run on ASSIGNMENT, not initialization — and a
/// didSet that spawns work (the icecubes fetch-trigger genre:
/// `var timeline { didSet { Task { await fetch() } } }`) executes.
@Suite struct PropertyObserverTests {
    private func run(_ source: String) throws -> RuntimeValue {
        try Interpreter(registry: ViewRegistry()).run(source: source)
    }

    @Test func didSetFiresOnAssignmentNotInit() throws {
        let result = try run("""
        class Model {
            var log: [String] = []
            var value = 0 {
                didSet { self.log.append("didSet \\(oldValue) -> \\(value)") }
            }
        }
        let model = Model()
        model.value = 5
        model.value = 7
        model.log.joined(separator: ", ")
        """)
        #expect(result.stringValue == "didSet 0 -> 5, didSet 5 -> 7")
    }

    @Test func willSetSeesNewValue() throws {
        let result = try run("""
        struct Holder {
            var notes = ""
            var value = 1 {
                willSet { notes += "will \\(newValue);" }
                didSet { notes += "did \\(oldValue);" }
            }
        }
        var holder = Holder()
        holder.value = 9
        holder.notes
        """)
        #expect(result.stringValue == "will 9;did 1;")
    }

    @Test func assignmentInsideDidSetDoesNotRetrigger() throws {
        let result = try run("""
        class Clamp {
            var hits = 0
            var value = 0 {
                didSet {
                    hits += 1
                    if value > 10 { value = 10 }
                }
            }
        }
        let clamp = Clamp()
        clamp.value = 50
        (clamp.value, clamp.hits)
        """)
        #expect(result.stringified == "(10, 1)")
    }

    @Test func customObserverParameterNames() throws {
        let result = try run("""
        class Named {
            var trace = ""
            var value = 0 {
                willSet(incoming) { trace += "in:\\(incoming);" }
                didSet(previous) { trace += "was:\\(previous);" }
            }
        }
        let named = Named()
        named.value = 3
        named.trace
        """)
        #expect(result.stringValue == "in:3;was:0;")
    }
}
