import Testing
@testable import SwiftInterpreter

private func evaluateValueSemantics(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite("Core value semantics")
struct CoreValueSemanticsTests {
    @Test func dictionaryAssignmentDoesNotAlias() throws {
        let source = #"""
        var original = ["count": 1]
        var copy = original
        copy["count"] = 2
        "\(original["count"]!) \(copy["count"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 2")
    }

    @Test func tupleAssignmentDoesNotAlias() throws {
        let source = #"""
        var original = (x: 1, y: 2)
        var copy = original
        copy.x = 9
        "\(original.x) \(copy.x)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 9")
    }

    @Test func nestedContainerMutationUsesCopyInCopyOut() throws {
        let source = #"""
        var original = [["count": 1]]
        var copy = original
        copy[0]["count"] = 3
        "\(original[0]["count"]!) \(copy[0]["count"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 3")
    }

    @Test func functionArgumentAndReturnPreserveValueSemantics() throws {
        let source = #"""
        func changed(_ input: [String: Int]) -> [String: Int] {
            var result = input
            result["count"] = 4
            return result
        }

        var original = ["count": 1]
        let result = changed(original)
        "\(original["count"]!) \(result["count"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1 4")
    }

    @Test func reduceIntoMutatesItsValueAccumulator() throws {
        let source = #"""
        let counts = ["a", "bb", "a"].reduce(into: [:]) { result, value in
            result[value, default: 0] += 1
        }
        "\(counts["a"]!) \(counts["bb"]!)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "2 1")
    }

    @Test func arrayInsertContentsUsesCopyInCopyOut() throws {
        let source = #"""
        var values = [1, 4]
        values.insert(contentsOf: [2, 3], at: 1)
        values.map(String.init).joined(separator: ",")
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "1,2,3,4")
    }

    @Test func initializerUsesItsOwnLexicalNestedTypes() throws {
        let source = """
        struct Settings {
            struct Keys { static let value = 7 }
            var value: Int
            init() { self.value = Keys.value }
        }
        struct Container {
            func load() -> Settings { Settings() }
        }
        Container().load().value
        """

        #expect(try evaluateValueSemantics(source).intValue == 7)
    }

    @Test func computedPropertyUsesItsOwnLexicalNestedTypes() throws {
        let source = """
        struct First {
            enum Layout { static let unrelated = 1 }
        }
        struct Second {
            enum Layout { static let menuWidth = 220 }
            var width: Int { Layout.menuWidth }
        }
        Second().width
        """

        #expect(try evaluateValueSemantics(source).intValue == 220)
    }

    @Test func deferredClosureKeepsItsLexicalNestedTypes() throws {
        let source = """
        var deferred: (() -> Int)!
        struct Owner {
            enum Layout { static let value = 7 }
            func install() { deferred = { Layout.value } }
        }
        struct Caller {
            enum Layout { static let unrelated = 1 }
            func call() -> Int { deferred() }
        }
        Owner().install()
        Caller().call()
        """

        #expect(try evaluateValueSemantics(source).intValue == 7)
    }

    @Test func viewBodyUsesItsOwnLexicalNestedTypes() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        struct First {
            enum Layout { static let unrelated = 1 }
        }
        struct Root: View {
            enum Layout { static let value = 9 }
            var body: some View { Layout.value }
        }
        """)
        let root = try #require(interpreter.structSymbols.first { $0.name == "Root" })
        guard case .instance(let instance) = try interpreter.instantiateRoot(root) else {
            Issue.record("root should instantiate as an interpreted instance")
            return
        }

        #expect(try interpreter.evaluateBody(of: instance).intValue == 9)
    }

    @Test func nestedTypeLookupSearchesOutwardThroughLexicalFrames() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: """
        struct Outer {
            enum Layout { static let value = 11 }
        }
        struct Inner {}
        """)
        let outer = try #require(interpreter.structSymbols.first { $0.name == "Outer" })
        let inner = try #require(interpreter.structSymbols.first { $0.name == "Inner" })
        interpreter.lexicalOwnerFrames = [outer, inner]

        guard case .enumType(let layout)? = interpreter.lexicalNestedType("Layout", runtime: inner) else {
            Issue.record("outer lexical frame's nested type should remain visible")
            return
        }
        #expect(try interpreter.staticMember("value", of: layout)?.intValue == 11)
    }

    @Test func rootInstantiationGetsAFreshEvaluationBudget() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: "struct Root { var value = 7 }")
        let root = try #require(interpreter.structSymbols.first { $0.name == "Root" })

        interpreter.steps = interpreter.stepBudget

        let value = try interpreter.instantiateRoot(root)
        guard case .instance(let instance) = value else {
            Issue.record("root should instantiate as an interpreted instance")
            return
        }
        #expect(instance.box(for: "value")?.value.intValue == 7)
    }

    @Test func typedComputedReceiverUsesItsUserSubscriptSetter() throws {
        let source = """
        class Token {}
        class Controller {}
        class Manager {
            static let shared = Manager()
            private var values = [Token: Controller]()

            subscript(_ token: Token) -> Controller? {
                get { values[token] }
                set { values[token] = newValue }
            }
        }
        struct Action {
            private var manager: Manager { .shared }

            func open() -> Bool {
                let token = Token()
                manager[token] = Controller()
                return manager[token] != nil
            }
        }
        Action().open()
        """

        #expect(try evaluateValueSemantics(source).boolValue == true)
    }

    @Test func contextualReceiverEvaluatesItsMemberBaseOnce() throws {
        let source = #"""
        class Token {}
        class Manager {
            static let shared = Manager()
            subscript(_ token: Token) -> Int? { 7 }
        }
        struct Owner {
            var manager: Manager { .shared }
        }
        var constructions = 0
        func makeOwner() -> Owner {
            constructions += 1
            return Owner()
        }
        let token = Token()
        let result = makeOwner().manager[token]
        "\(result!) \(constructions)"
        """#

        #expect(try evaluateValueSemantics(source).stringValue == "7 1")
    }
}
