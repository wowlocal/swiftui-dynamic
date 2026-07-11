import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The Swift Testing half of the harness: @Test discovery, #expect/#require
/// via macro-host dispatch, parameterized cases, failure classification.
@Suite struct SwiftTestingHarnessTests {
    @Test func discoversAndRunsSuiteStructs() throws {
        let source = """
        struct Parser {
            func double(_ s: String) -> Int? {
                Int(s).map { $0 * 2 }
            }
        }

        @Suite struct ParserTests {
            @Test func doublesNumbers() throws {
                let parser = Parser()
                let value = try #require(parser.double("21"))
                #expect(value == 42)
            }

            @Test func deliberateMiss() {
                let parser = Parser()
                #expect(parser.double("2") == 5, "should be four")
            }

            func helperNotATest() -> Int { 7 }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.results.count == 2)
        #expect(report.passed == 1)
        #expect(report.failed == 1)
        let failing = report.results.first { $0.testName == "deliberateMiss" }
        guard case .failed(let reasons)? = failing?.outcome else {
            Issue.record("expected deliberateMiss to fail")
            return
        }
        #expect(reasons.first?.contains("should be four") == true)
    }

    @Test func requireFailureIsAFailureNotAnError() throws {
        let source = """
        @Suite struct RequireTests {
            @Test func unwrapMissing() throws {
                let missing = Int("nope")
                let value = try #require(missing)
                #expect(value == 1)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.failed == 1)
        #expect(report.errored == 0)
    }

    @Test func expectThrowsForm() throws {
        let source = """
        enum Fault: Error {
            case broken
        }

        struct Machine {
            func run(_ ok: Bool) throws -> Int {
                if !ok {
                    throw Fault.broken
                }
                return 1
            }
        }

        @Suite struct ThrowTests {
            @Test func failureThrows() {
                #expect(throws: Fault.self) {
                    _ = try Machine().run(false)
                }
            }

            @Test func successDoesNotThrowButWeExpectedIt() {
                #expect(throws: Fault.self) {
                    _ = try Machine().run(true)
                }
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.passed == 1)
        #expect(report.failed == 1)
    }

    // clean-architecture's RequestMocking genre: the suite clears a STATIC
    // mock store in `deinit`. Swift Testing deallocates the per-test
    // instance right after its test (deinit is the documented tearDown
    // replacement), so each test starts with an empty store — without it,
    // stale mocks accumulate and first-match serves the wrong response.
    @Test func deinitRunsBetweenSuiteTests() throws {
        let source = """
        final class Registry {
            static var mocks: [String] = []
            static func add(_ mock: String) { mocks.append(mock) }
            static func removeAll() { mocks.removeAll() }
        }

        @Suite(.serialized) final class MockLifecycleTests {
            deinit {
                Registry.removeAll()
            }

            @Test func first() {
                Registry.add("A")
                #expect(Registry.mocks == ["A"])
            }

            @Test func second() {
                Registry.add("B")
                #expect(Registry.mocks == ["B"])
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.results.count == 2)
        #expect(report.passed == 2)
        #expect(report.failed == 0)
    }

    @Test func parameterizedSingleCollection() throws {
        let source = """
        @Suite struct EvenTests {
            @Test(arguments: [2, 4, 5, 8])
            func isEven(value: Int) {
                #expect(value % 2 == 0)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.results.count == 4)
        #expect(report.passed == 3)
        #expect(report.failed == 1)
        let failing = report.results.first { if case .failed = $0.outcome { true } else { false } }
        #expect(failing?.testName == "isEven[2]")
    }

    @Test func multiCollectionParameterizedIsSkippedHonestly() throws {
        let source = """
        @Suite struct PairTests {
            @Test(arguments: [1, 2], ["a", "b"])
            func pairs(x: Int, s: String) {
                #expect(x > 0)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.skipped == 1)
        #expect(report.passed == 0)
    }

    @Test func plainStructWithTestsNeedsNoSuiteAttribute() throws {
        let source = """
        struct LooseTests {
            @Test func arithmetic() {
                #expect(1 + 1 == 2)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.passed == 1)
    }
}

/// Cross-validation against the real compiler. This exact suite ran natively
/// via `swift test` (Swift Testing) on 2026-07-09: requireUnwraps and
/// expectedThrow passed; stringAndArrays failed (joined count is 19, not
/// 20 — a data bug the NATIVE run caught), deliberateMiss failed, and
/// divisibleByThree failed exactly one case (value 10). Interpreted verdicts
/// must match test-for-test, parameterized cases included.
@Suite struct SwiftTestingNativeCrossCheck {
    @Test func verdictsMatchNativeRun() throws {
        let source = """
        enum Fault: Error {
            case broken
        }

        struct Machine {
            func run(_ ok: Bool) throws -> Int {
                if !ok {
                    throw Fault.broken
                }
                return 1
            }
        }

        @Suite struct SwiftTestingCrossCheck {
            @Test func stringAndArrays() {
                let words = ["delta", "alpha", "charlie"]
                #expect(words.sorted().first == "alpha")
                #expect(words.joined(separator: "-").count == 20)
            }

            @Test func requireUnwraps() throws {
                let value = try #require(Int("42"))
                #expect(value / 6 == 7)
            }

            @Test func deliberateMiss() {
                #expect(1 + 1 == 3, "two plus two")
            }

            @Test func expectedThrow() {
                #expect(throws: Fault.self) {
                    _ = try Machine().run(false)
                }
            }

            @Test(arguments: [3, 6, 9, 10])
            func divisibleByThree(value: Int) {
                #expect(value % 3 == 0)
            }
        }
        """
        let report = try TestHarness.run(source: source)
        #expect(report.results.count == 8)
        #expect(report.passed == 5)
        #expect(report.failed == 3)
        #expect(report.errored == 0)
        let failedNames = report.results
            .compactMap { if case .failed = $0.outcome { $0.testName } else { nil } }
            .sorted()
        #expect(failedNames == ["deliberateMiss", "divisibleByThree[3]", "stringAndArrays"])
    }
}
