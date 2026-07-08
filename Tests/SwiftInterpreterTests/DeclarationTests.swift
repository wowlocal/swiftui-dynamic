import Testing
@testable import SwiftInterpreter

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct DeclarationTests {
    @Test func topLevelLetAndVar() throws {
        #expect(try eval("let x = 5\nx + 2").intValue == 7)
        #expect(try eval("var x = 1\nx = 10\nx").intValue == 10)
        #expect(try eval("var x = 1\nx += 4\nx").intValue == 5)
    }

    @Test func topLevelFunction() throws {
        let source = """
        func add(a: Int, b: Int) -> Int {
            return a + b
        }
        add(a: 2, b: 3)
        """
        #expect(try eval(source).intValue == 5)
    }

    @Test func functionImplicitReturn() throws {
        let source = """
        func double(n: Int) -> Int { n * 2 }
        double(n: 21)
        """
        #expect(try eval(source).intValue == 42)
    }

    @Test func functionDefaultParameter() throws {
        let source = """
        func greet(name: String = "world") -> String { "hi " + name }
        greet()
        """
        #expect(try eval(source).stringValue == "hi world")
    }

    @Test func structWithStoredProperties() throws {
        let source = """
        struct Point {
            var x = 0
            var y = 0
        }
        let p = Point(x: 3, y: 4)
        p.x + p.y
        """
        #expect(try eval(source).intValue == 7)
    }

    @Test func structMethodMutatesViaImplicitSelf() throws {
        // Divergence under test: interpreted structs are reference-backed.
        let source = """
        struct Counter {
            var count = 1
            mutating func bump() {
                count += 2
            }
        }
        let c = Counter()
        c.bump()
        c.count
        """
        #expect(try eval(source).intValue == 3)
    }

    @Test func structComputedProperty() throws {
        let source = """
        struct Circle {
            var radius = 2.0
            var diameter: Double { radius * 2 }
        }
        Circle().diameter
        """
        #expect(try eval(source).doubleValue == 4.0)
    }

    @Test func methodUsesExplicitSelf() throws {
        let source = """
        struct Box {
            var value = 10
            func read() -> Int { return self.value }
        }
        Box().read()
        """
        #expect(try eval(source).intValue == 10)
    }

    @Test func memberAssignment() throws {
        let source = """
        struct P { var x = 0 }
        let p = P()
        p.x = 9
        p.x
        """
        #expect(try eval(source).intValue == 9)
    }

    @Test func badMemberwiseArgumentThrows() throws {
        #expect(throws: RuntimeError.self) {
            try eval("struct P { var x = 0 }\nP(y: 1)")
        }
    }
}
