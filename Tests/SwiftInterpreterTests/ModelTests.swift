import Testing
@testable import SwiftInterpreter

@Suite struct ModelTests {
    private final class Token {}
    private let token = Token()

    @Test func classesAreReferences() throws {
        let source = """
        class Counter {
            var n = 0
            func bump() {
                n += 1
            }
        }
        let a = Counter()
        let b = a
        b.bump()
        b.bump()
        a.n
        """
        #expect(try Interpreter().run(source: source).intValue == 2)
    }

    @Test func classWithCustomInitAndStatics() throws {
        let source = """
        class Logger {
            static let prefix = ">> "
            var lines: [String] = []

            init(first: String) {
                lines.append(Logger.prefix + first)
            }

            func log(_ message: String) {
                lines.append(Logger.prefix + message)
            }
        }
        let l = Logger(first: "hello")
        l.log("world")
        l.lines.joined(separator: "|")
        """
        #expect(try Interpreter().run(source: source).stringValue == ">> hello|>> world")
    }

    private let storeSource = """
    class Store: ObservableObject {
        @Published var count = 0
        @Published var name = ""
        var untracked = 0

        func bump() {
            count += 1
        }
    }
    let store = Store()
    """

    @Test func publishedMutationFiresChangeSignal() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: storeSource)
        guard case .instance(let store)? = interpreter.globals.lookup("store") else {
            Issue.record("expected a store instance")
            return
        }
        #expect(store.symbol.isClass)
        #expect(store.symbol.isObservable)

        var fires = 0
        store.changeSignal.subscribe(ObjectIdentifier(token)) { fires += 1 }

        try interpreter.run(source: "store.bump()")
        #expect(fires == 1)
        try interpreter.run(source: "store.name = \"ada\"")
        #expect(fires == 2)
        // Non-@Published property writes don't notify on ObservableObject.
        try interpreter.run(source: "store.untracked = 9")
        #expect(fires == 2)
        #expect(store.box(for: "count")?.value.intValue == 1)
    }

    @Test func observableMacroTracksAllStoredProperties() throws {
        let source = """
        @Observable
        class Model {
            var value = 0
        }
        let m = Model()
        """
        let interpreter = Interpreter()
        try interpreter.run(source: source)
        guard case .instance(let model)? = interpreter.globals.lookup("m") else {
            Issue.record("expected a model instance")
            return
        }
        var fires = 0
        model.changeSignal.subscribe(ObjectIdentifier(token)) { fires += 1 }
        try interpreter.run(source: "m.value = 7")
        #expect(fires == 1)
    }

    @Test func plainClassDoesNotNotify() throws {
        let source = """
        class Bag {
            var value = 0
        }
        let bag = Bag()
        """
        let interpreter = Interpreter()
        try interpreter.run(source: source)
        guard case .instance(let bag)? = interpreter.globals.lookup("bag") else {
            Issue.record("expected an instance")
            return
        }
        var fires = 0
        bag.changeSignal.subscribe(ObjectIdentifier(token)) { fires += 1 }
        try interpreter.run(source: "bag.value = 3")
        #expect(fires == 0)
    }
}
