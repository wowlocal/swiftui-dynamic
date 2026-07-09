import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The harness itself: discovery, fresh-instance-per-test, setUp/tearDown,
/// assertion recording, and failure isolation.
@Suite struct TestHarnessTests {
    @Test func discoversRunsAndClassifies() throws {
        let source = """
        struct Calculator {
            func add(_ a: Int, _ b: Int) -> Int { a + b }
            func divide(_ a: Int, _ b: Int) -> Int { a / b }
        }

        final class CalculatorTests: XCTestCase {
            var calc: Calculator!

            override func setUp() {
                calc = Calculator()
            }

            func testAddition() {
                XCTAssertEqual(calc.add(2, 3), 5)
                XCTAssertTrue(calc.add(-1, 1) == 0, "zero sum")
            }

            func testDeliberateFailure() {
                XCTAssertEqual(calc.add(2, 2), 5, "math is broken")
            }

            func testErrorIsolation() {
                let boom = [1, 2][9]
                XCTAssertEqual(boom, 0)
            }

            func helperNotATest() {
                XCTFail("must never run")
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.results.count == 3)
        #expect(report.passed == 1)
        #expect(report.failed == 1)
        #expect(report.errored == 1)

        let failure = report.results.first { $0.testName == "testDeliberateFailure" }
        guard case .failed(let reasons)? = failure?.outcome else {
            Issue.record("expected recorded assertion failure")
            return
        }
        #expect(reasons.first?.contains("math is broken") == true)
    }

    @Test func freshInstancePerTest() throws {
        let source = """
        final class CounterTests: XCTestCase {
            var hits = 0

            func testOne() {
                hits += 1
                XCTAssertEqual(hits, 1)
            }

            func testTwo() {
                hits += 1
                XCTAssertEqual(hits, 1)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.passed == 2)
        #expect(report.failed == 0)
    }

    @Test func unwrapAndComparisons() throws {
        let source = """
        final class MiscTests: XCTestCase {
            func testUnwrapAndCompare() throws {
                let value: Int? = 7
                let unwrapped = try XCTUnwrap(value)
                XCTAssertGreaterThan(unwrapped, 5)
                XCTAssertLessThanOrEqual(unwrapped, 7)
                XCTAssertNil(Int("nope"))
                XCTAssertNotNil(Int("42"))
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.passed == 1)
        #expect(report.failed == 0)
        #expect(report.errored == 0)
    }
}
