import Testing
@testable import SwiftInterpreter

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct ControlFlowTests {
    @Test func ifElse() throws {
        let source = """
        func sign(n: Int) -> Int {
            if n > 0 {
                return 1
            } else if n < 0 {
                return -1
            } else {
                return 0
            }
        }
        sign(n: -5)
        """
        #expect(try eval(source).intValue == -1)
    }

    @Test func ifAsStatementMutating() throws {
        let source = """
        var x = 0
        if true {
            x = 5
        }
        x
        """
        #expect(try eval(source).intValue == 5)
    }

    @Test func whileLoop() throws {
        let source = """
        var sum = 0
        var i = 1
        while i <= 4 {
            sum += i
            i += 1
        }
        sum
        """
        #expect(try eval(source).intValue == 10)
    }

    @Test func forInRange() throws {
        let source = """
        var s = 0
        for i in 0..<5 {
            s += i
        }
        s
        """
        #expect(try eval(source).intValue == 10)
    }

    @Test func forInClosedRange() throws {
        let source = """
        var s = 0
        for i in 1...3 {
            s += i
        }
        s
        """
        #expect(try eval(source).intValue == 6)
    }

    @Test func forInArray() throws {
        let source = """
        var joined = ""
        for name in ["a", "b", "c"] {
            joined += name
        }
        joined
        """
        #expect(try eval(source).stringValue == "abc")
    }

    @Test func breakAndContinue() throws {
        let source = """
        var s = 0
        for i in 0..<10 {
            if i == 3 {
                continue
            }
            if i == 6 {
                break
            }
            s += i
        }
        s
        """
        // 0+1+2+4+5 = 12
        #expect(try eval(source).intValue == 12)
    }

    @Test func infiniteLoopHitsStepBudget() throws {
        do {
            _ = try eval("while true { }")
            Issue.record("expected the step budget to trip")
        } catch let e as RuntimeError {
            #expect(e.message.contains("budget"))
        }
    }

    @Test func runawayRecursionIsAFatalLocatedError() throws {
        do {
            _ = try eval("func f() -> Int { return f() }\nf()")
            Issue.record("expected the depth guard to trip")
        } catch let e as RuntimeError {
            #expect(e.message.contains("call depth"))
            #expect(e.fatal)
        }
        // Self-recursive computed properties too.
        do {
            _ = try eval("struct S { var x: Int { x } }\nS().x")
            Issue.record("expected the depth guard to trip")
        } catch let e as RuntimeError {
            #expect(e.message.contains("call depth"))
        }
    }

    @Test func nestedFunctionAndRecursion() throws {
        let source = """
        func fib(n: Int) -> Int {
            if n < 2 {
                return n
            }
            return fib(n: n - 1) + fib(n: n - 2)
        }
        fib(n: 10)
        """
        #expect(try eval(source).intValue == 55)
    }
}
