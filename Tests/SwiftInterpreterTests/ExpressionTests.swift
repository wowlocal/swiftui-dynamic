import Testing
@testable import SwiftInterpreter

private func eval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct ExpressionTests {
    @Test func operatorPrecedence() throws {
        #expect(try eval("1 + 2 * 3").intValue == 7)
        #expect(try eval("(1 + 2) * 3").intValue == 9)
        #expect(try eval("10 - 2 - 3").intValue == 5)
    }

    @Test func integerDivisionAndPromotion() throws {
        #expect(try eval("10 / 4").intValue == 2)
        #expect(try eval("10.0 / 4").doubleValue == 2.5)
        #expect(try eval("1 + 0.5").doubleValue == 1.5)
    }

    @Test func divisionByZeroThrows() throws {
        #expect(throws: RuntimeError.self) { try eval("1 / 0") } // Int traps, like Swift
    }

    /// Double division follows IEEE 754 exactly like real Swift.
    @Test func doubleDivisionByZeroIsIEEE() throws {
        #expect(try eval("(1.0 / 0.0) > 1000000").boolValue == true)
        #expect(try eval("(-1.0 / 0.0) < -1000000").boolValue == true)
        #expect(try eval("(0.0 / 0.0) == (0.0 / 0.0)").boolValue == false) // NaN != NaN
        #expect(try eval("let w = 390.0\n20 / (w - 390) > 0").boolValue == true)
    }

    @Test func tupleElementsAreAssignable() throws {
        let source = """
        var pair = (1, true)
        pair.0 = 5
        pair.1.toggle()
        pair.0 + (pair.1 ? 0 : 100)
        """
        #expect(try eval(source).intValue == 105)
        let labeled = """
        var point = (x: 1, y: 2)
        point.x += 10
        point.x + point.y
        """
        #expect(try eval(labeled).intValue == 13)
    }

    /// DispatchTime deadlines: the `.now()` anchor absorbs into the offset.
    @Test func nowAnchorArithmeticYieldsOffsetSeconds() throws {
        #expect(try eval(".now() + 0.5").doubleValue == 0.5)
        #expect(try eval(".now() + 3").doubleValue == 3)
        #expect(try eval(".now() - 2").doubleValue == -2)
    }

    @Test func stringConcatAndInterpolation() throws {
        #expect(try eval(#""a" + "b""#).stringValue == "ab")
        #expect(try eval(#""n=\(2 + 3)""#).stringValue == "n=5")
        #expect(try eval(#""hi \("there".uppercased())""#).stringValue == "hi THERE")
        #expect(try eval(#""line\nbreak""#).stringValue == "line\nbreak")
    }

    @Test func booleansAndComparison() throws {
        #expect(try eval("true && false").boolValue == false)
        #expect(try eval("true || false").boolValue == true)
        #expect(try eval("!true").boolValue == false)
        #expect(try eval("1 < 2").boolValue == true)
        #expect(try eval("2 <= 1").boolValue == false)
        #expect(try eval(#""a" == "a""#).boolValue == true)
        #expect(try eval("1 != 2").boolValue == true)
    }

    @Test func shortCircuit() throws {
        // RHS would divide by zero; && must not evaluate it.
        #expect(try eval("false && 1 / 0 == 0").boolValue == false)
        #expect(try eval("true || 1 / 0 == 0").boolValue == true)
    }

    @Test func ternary() throws {
        #expect(try eval("1 < 2 ? 10 : 20").intValue == 10)
        #expect(try eval("1 > 2 ? 10 : 20").intValue == 20)
    }

    @Test func arrays() throws {
        #expect(try eval("[1, 2, 3][1]").intValue == 2)
        #expect(try eval("[1, 2, 3].count").intValue == 3)
        #expect(try eval("[].isEmpty").boolValue == true)
        #expect(try eval("[1, 2] + [3]").arrayValue?.count == 3)
    }

    @Test func ranges() throws {
        let half = try eval("0..<3")
        if case .native(let any) = half, let range = any as? Range<Int> {
            #expect(range == 0..<3)
        } else {
            Issue.record("expected a Range<Int>")
        }
        let closed = try eval("1...3")
        if case .native(let any) = closed, let range = any as? Range<Int> {
            #expect(range == 1..<4)
        } else {
            Issue.record("expected a Range<Int>")
        }
    }

    @Test func prefixMinus() throws {
        #expect(try eval("-5 + 2").intValue == -3)
    }

    @Test func parseErrorIsLocated() throws {
        do {
            _ = try eval("let x = \"")
            Issue.record("expected a parse error")
        } catch let e as RuntimeError {
            #expect(e.line == 1)
            #expect(!e.message.isEmpty)
        }
    }

    @Test func unresolvedIdentifierIsLocated() throws {
        do {
            _ = try eval("nope + 1")
            Issue.record("expected an error")
        } catch let e as RuntimeError {
            #expect(e.message.contains("nope"))
            #expect(e.line == 1)
        }
    }
}
