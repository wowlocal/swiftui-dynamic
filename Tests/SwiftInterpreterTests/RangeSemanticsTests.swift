import Foundation
import Testing
@testable import SwiftInterpreter

private func rangeEval(_ source: String) throws -> RuntimeValue {
    try Interpreter().run(source: source)
}

@Suite struct RangeSemanticsTests {
    @Test func constructionPreservesShapeAndPromotesMixedNumbers() throws {
        let half = try #require(try rangeEval("0.5..<3").rangeValue)
        #expect(half.lowerBound?.doubleValue == 0.5)
        #expect(half.upperBound?.doubleValue == 3.0)
        #expect(!half.includesUpperBound)

        let mixed = try #require(try rangeEval("0..<3.5").rangeValue)
        #expect(mixed.lowerBound?.doubleValue == 0.0)
        #expect(mixed.upperBound?.doubleValue == 3.5)
        #expect(!mixed.includesUpperBound)

        let closed = try #require(try rangeEval("1...3").rangeValue)
        #expect(closed.upperBound?.intValue == 3)
        #expect(closed.includesUpperBound)
    }

    @Test func annotatedRangesCoerceLiteralBounds() throws {
        let value = try rangeEval("let range: Range<Double> = 0..<3\nrange.lowerBound + range.upperBound")
        #expect(value.doubleValue == 3.0)

        let closed = try rangeEval("let range: ClosedRange<Double> = 0...3\nrange.upperBound")
        #expect(closed.doubleValue == 3.0)
    }

    @Test func rangeMembersKeepNativeSemantics() throws {
        #expect(try rangeEval("(1...3).upperBound").intValue == 3)
        #expect(try rangeEval("(1...3).count").intValue == 3)
        #expect(try rangeEval("(0..<0).isEmpty").boolValue == true)
        #expect(try rangeEval("(0...0).isEmpty").boolValue == false)
        #expect(try rangeEval("(0.0..<3.0).contains(3.0)").boolValue == false)
        #expect(try rangeEval("(0.0...3.0).contains(3.0)").boolValue == true)
    }

    @Test func explicitMatchOperatorSupportsFullAndPartialRanges() throws {
        let source = """
        (0..<3 ~= 2)
            && !(0..<3 ~= 3)
            && (0...3 ~= 3)
            && ((...3) ~= -100)
            && !((..<3) ~= 3)
            && ((3...) ~= 100)
        """
        #expect(try rangeEval(source).boolValue == true)
    }

    @Test func doubleSwitchUsesIntegerLiteralRangeContext() throws {
        let source = """
        func bucket(_ value: Double) -> String {
            switch value {
            case 0..<3: return "low"
            case 3..<6: return "mid"
            case 6...8: return "high"
            default: return "out"
            }
        }
        bucket(0.0) + bucket(2.999) + bucket(3.0) + bucket(5.999)
            + bucket(6.0) + bucket(8.0) + bucket(8.001)
        """
        #expect(try rangeEval(source).stringValue == "lowlowmidmidhighhighout")
    }

    @Test func stringAndDateRangesMatch() throws {
        let source = """
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 10)
        ("A"..<"H" ~= "C") && !("A"..<"H" ~= "H") && (start...end ~= end)
        """
        #expect(try rangeEval(source).boolValue == true)
    }

    @Test func customTopLevelMatchOperatorDrivesSwitchAndExpression() throws {
        let source = """
        struct Near {
            let target: Int
        }
        func ~= (_ pattern: Near, _ value: Int) -> Bool {
            abs(pattern.target - value) <= 1
        }
        func label(_ value: Int) -> String {
            switch value {
            case Near(target: 10): return "near"
            default: return "far"
            }
        }
        label(9) + label(12) + (Near(target: 4) ~= 5 ? "yes" : "no")
        """
        #expect(try rangeEval(source).stringValue == "nearfaryes")
    }

    @Test func customStaticMatchOperatorDrivesSwitch() throws {
        let source = """
        struct MultipleOf {
            let divisor: Int
            static func ~= (_ pattern: MultipleOf, _ value: Int) -> Bool {
                value % pattern.divisor == 0
            }
        }
        switch 12 {
        case MultipleOf(divisor: 5): "five"
        case MultipleOf(divisor: 3): "three"
        default: "none"
        }
        """
        #expect(try rangeEval(source).stringValue == "three")
    }

    /// A dependency may declare a specialized pattern operator in one source
    /// file. It is not a candidate for unrelated enum switches merely because
    /// both calls have two unlabeled arguments; native overload resolution
    /// first requires the runtime operands to satisfy the parameter types.
    @Test func unrelatedCustomPatternOperatorDoesNotCaptureEnumSwitch() throws {
        let source = """
        enum LoadingState {
            case loading
            case display([Int])
        }

        fileprivate func ~= (_ pattern: [String], _ value: String) -> Bool {
            pattern.contains(value)
        }

        let state = LoadingState.display([1, 2, 3])
        switch state {
        case .loading: "loading"
        case .display: "display"
        }
        """
        #expect(try rangeEval(source).stringValue == "display")
    }

    /// A closed range subscript keeps its upper bound, and the `ArraySlice` it
    /// produces keeps its BASE's index space. This test previously read the
    /// slice as `middle[0], middle[1]`, which is the re-based reading the
    /// interpreter used to produce; the real compiler traps on `middle[0]`
    /// ("Swift/SliceBuffer.swift:307: Fatal error: Index out of bounds") and
    /// answers `startIndex == 1`, `endIndex == 3`. The expectation is the
    /// compiler's, checked by compiling this same slice with `swiftc`.
    @Test func integerRangesIterateAndSliceWithoutLosingClosedness() throws {
        let source = """
        var total = 0
        for value in 1...3 { total += value }
        let middle = [10, 20, 30, 40][1...2]
        let prefix = "abcd"[..<2]
        let suffix = "abcd"[2...]
        "\\(total):\\(middle[1]),\\(middle[2]):\\(prefix):\\(suffix)"
        """
        #expect(try rangeEval(source).stringValue == "6:20,30:ab:cd")
    }

    /// The index space the case above depends on, stated on its own so a
    /// regression names the rule rather than a string mismatch.
    @Test func closedRangeSliceKeepsItsBaseIndexSpace() throws {
        let source = """
        let middle = [10, 20, 30, 40][1...2]
        "\\(middle.startIndex),\\(middle.endIndex),\\(middle.count)"
        """
        #expect(try rangeEval(source).stringValue == "1,3,2")
    }

    @Test func unboundedRangeSubscriptsReturnWholeCollectionSlices() throws {
        let source = """
        func copy(_ value: Substring) -> String { String(value) }
        let text = "p.quote-inline"
        let numbers = [10, 20, 30]
        "\\(copy(text[...])):\\(numbers[...].count)"
        """
        #expect(try rangeEval(source).stringValue == "p.quote-inline:3")
    }

    @Test func descendingRangeProducesLocatedError() throws {
        do {
            _ = try rangeEval("3..<0")
            Issue.record("expected invalid bounds")
        } catch let error as RuntimeError {
            #expect(error.line == 1)
            #expect(error.message.contains("invalid range bounds"))
        }
    }
}
