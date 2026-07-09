import SwiftInterpreter

/// Runs a project's OWN XCTest suite over the interpreted code — the
/// author-written semantic oracle. Both halves are interpreted: the merged
/// module holds app sources plus test sources, XCTAssert* are host functions
/// recording into an AssertionRecorder, and each test method runs on a fresh
/// instance of its XCTestCase subclass with setUp/tearDown honored.
public enum TestHarness {
    public enum Outcome {
        case passed
        /// Assertions fired — a real semantic divergence (or an absorbed
        /// environment the test genuinely depends on).
        case failed(reasons: [String])
        /// The test body threw before finishing — missing interpreter
        /// feature, absorbed dependency, or a genuine crash.
        case errored(message: String)
    }

    public struct TestResult {
        public let className: String
        public let testName: String
        public let outcome: Outcome
    }

    public struct Report {
        public let results: [TestResult]

        public var passed: Int { results.filter { if case .passed = $0.outcome { true } else { false } }.count }
        public var failed: Int { results.filter { if case .failed = $0.outcome { true } else { false } }.count }
        public var errored: Int { results.filter { if case .errored = $0.outcome { true } else { false } }.count }
    }

    public static func run(source: String) throws -> Report {
        let recorder = AssertionRecorder()
        let registry = ViewRegistry()
        registry.registerXCTestGateways(recorder)
        let interpreter = Interpreter(registry: registry)
        do {
            try interpreter.run(source: source, lazyTopLevelGlobals: true)
        } catch {
            throw RuntimeError(message: "top-level threw: \(error)")
        }

        var results: [TestResult] = []
        for symbol in interpreter.structSymbols where symbol.conformances.contains("XCTestCase") {
            let testNames = symbol.methods.keys
                .filter { $0.hasPrefix("test") }
                .sorted()
            for testName in testNames {
                results.append(runSingle(testName, of: symbol, interpreter: interpreter, recorder: recorder))
            }
        }
        return Report(results: results)
    }

    private static func runSingle(
        _ testName: String, of symbol: StructSymbol,
        interpreter: Interpreter, recorder: AssertionRecorder
    ) -> TestResult {
        recorder.reset()
        do {
            // XCTest semantics: a FRESH instance per test method.
            guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
                return TestResult(className: symbol.name, testName: testName,
                                  outcome: .errored(message: "could not instantiate test case"))
            }
            for hook in ["setUp", "setUpWithError"] where symbol.methods[hook] != nil {
                _ = try interpreter.callMethod(named: hook, on: instance, arguments: [])
            }
            defer {
                for hook in ["tearDown", "tearDownWithError"] where symbol.methods[hook] != nil {
                    _ = try? interpreter.callMethod(named: hook, on: instance, arguments: [])
                }
            }
            _ = try interpreter.callMethod(named: testName, on: instance, arguments: [])
            if recorder.failures.isEmpty {
                return TestResult(className: symbol.name, testName: testName, outcome: .passed)
            }
            return TestResult(className: symbol.name, testName: testName,
                              outcome: .failed(reasons: recorder.failures))
        } catch let error as RuntimeError {
            return TestResult(className: symbol.name, testName: testName,
                              outcome: .errored(message: error.description))
        } catch {
            return TestResult(className: symbol.name, testName: testName,
                              outcome: .errored(message: "\(error)"))
        }
    }
}

/// Collects assertion failures for the currently-running test.
public final class AssertionRecorder {
    public private(set) var failures: [String] = []

    public init() {}

    func reset() {
        failures = []
    }

    func record(_ message: String) {
        failures.append(message)
    }
}
