import Testing
@testable import SwiftInterpreter

/// Real Swift scoping on the WRITE side: locals first, implicit-self
/// members second, globals LAST — a class property named like a global
/// builtin (`log`, `min`) must not write into the builtin's box. The
/// SwiftUIFlux middleware genre chains through exactly these shapes.
@Suite struct BareMemberWriteTests {
    private func run(_ body: String) throws -> String {
        let source = """
        class S {
            var log: [String] = []
            func go() {
                \(body)
            }
        }
        let s = S()
        s.go()
        s.log.joined(separator: ",")
        """
        return try Interpreter().run(source: source).stringValue ?? "NIL"
    }

    @Test func bareWritesToBuiltinNamedProperties() throws {
        #expect(try run(#"log = ["x"]"#) == "x")
        #expect(try run(#"log = log + ["y"]"#) == "y")
        #expect(try run(#"log.append("w")"#) == "w")
        #expect(try run(#"self.log.append("v")"#) == "v")
    }

    @Test func weakSelfMethodCallDispatches() throws {
        let source = """
        class Store2 {
            var log: [String] = []
            func record(_ item: String) {
                log = log + [item]
            }
            func makeDispatch() -> (String) -> Void {
                return { [weak self] in self?.record($0) }
            }
        }
        let store = Store2()
        let dispatch = store.makeDispatch()
        dispatch("a")
        store.log.joined(separator: ",")
        """
        #expect(try Interpreter().run(source: source).stringValue == "a")
    }

    @Test func bareGlobalWritesStillLand() throws {
        let source = """
        var counter = 0
        func bump() {
            counter += 1
            counter = counter + 10
        }
        bump()
        counter
        """
        #expect(try Interpreter().run(source: source).intValue == 11)
    }
}
