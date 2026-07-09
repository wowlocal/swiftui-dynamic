import SwiftSyntax
import SwiftInterpreter

/// Runs a project's OWN test suites over the interpreted code — the
/// author-written semantic oracle. Both halves are interpreted: the merged
/// module holds app sources plus test sources; assertions are recording host
/// functions. Two frameworks are discovered:
/// - XCTest: XCTestCase subclasses (transitively — inherited test* methods
///   run in the subclass against its overrides), fresh instance per test,
///   setUp/tearDown honored.
/// - Swift Testing: @Test-attributed methods on any type (fresh instance per
///   test), #expect/#require executed via the macro-host dispatch,
///   single-collection `@Test(arguments:)` runs one case per element.
public enum TestHarness {
    public enum Outcome {
        case passed
        /// Assertions fired — a real semantic divergence (or an absorbed
        /// environment the test genuinely depends on).
        case failed(reasons: [String])
        /// The test body threw before finishing — missing interpreter
        /// feature, absorbed dependency, or a genuine crash.
        case errored(message: String)
        /// Not runnable by this harness yet (multi-collection parameterized
        /// tests, unevaluable argument collections).
        case skipped(reason: String)
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
        public var skipped: Int { results.filter { if case .skipped = $0.outcome { true } else { false } }.count }
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

        // Transitive XCTest discovery: a subclass of a test class is a test
        // class, and real XCTest runs INHERITED test methods in the subclass
        // too (against its overrides) — collect names up the superclass chain.
        var byName: [String: StructSymbol] = [:]
        for symbol in interpreter.structSymbols {
            byName[symbol.name] = symbol
        }
        var testClassNames = Set<String>()
        var grew = true
        while grew {
            grew = false
            for symbol in interpreter.structSymbols where !testClassNames.contains(symbol.name) {
                if symbol.conformances.contains("XCTestCase")
                    || symbol.conformances.contains(where: { testClassNames.contains($0) }) {
                    testClassNames.insert(symbol.name)
                    grew = true
                }
            }
        }

        var results: [TestResult] = []
        for symbol in interpreter.structSymbols where testClassNames.contains(symbol.name) {
            var testNames = Set<String>()
            var cursor: StructSymbol? = symbol
            var hops = 0
            while let current = cursor, hops < 16 {
                for name in current.methods.keys where name.hasPrefix("test") {
                    testNames.insert(name)
                }
                cursor = current.superclassName.flatMap { byName[$0] }
                hops += 1
            }
            for testName in testNames.sorted() {
                results.append(runSingle(testName, of: symbol, interpreter: interpreter, recorder: recorder))
            }
        }

        // Swift Testing: @Test methods on any non-XCTest type.
        for symbol in interpreter.structSymbols where !testClassNames.contains(symbol.name) {
            let attributed = symbol.methods
                .compactMap { name, decls in testAttribute(in: decls).map { (name: name, attribute: $0) } }
                .sorted { $0.name < $1.name }
            for entry in attributed {
                results.append(contentsOf: runSwiftTest(
                    entry.name, attribute: entry.attribute, of: symbol,
                    interpreter: interpreter, recorder: recorder))
            }
        }
        return Report(results: results)
    }

    // MARK: - Swift Testing

    private static func testAttribute(in decls: [FunctionDeclSyntax]) -> AttributeSyntax? {
        for decl in decls {
            for element in decl.attributes {
                guard let attribute = element.as(AttributeSyntax.self) else { continue }
                let name = attribute.attributeName.trimmedDescription
                if name == "Test" || name.hasSuffix(".Test") {
                    return attribute
                }
            }
        }
        return nil
    }

    private static func runSwiftTest(
        _ testName: String, attribute: AttributeSyntax, of symbol: StructSymbol,
        interpreter: Interpreter, recorder: AssertionRecorder
    ) -> [TestResult] {
        // `@Test(arguments: collection)` — one case per element. Multi-
        // collection (cartesian/zip) forms are skipped honestly.
        guard case .argumentList(let list)? = attribute.arguments else {
            return [runSingle(testName, of: symbol, interpreter: interpreter, recorder: recorder)]
        }
        let elements = Array(list)
        guard let argumentsIndex = elements.firstIndex(where: { $0.label?.text == "arguments" }) else {
            return [runSingle(testName, of: symbol, interpreter: interpreter, recorder: recorder)]
        }
        guard argumentsIndex == elements.count - 1 else {
            return [TestResult(className: symbol.name, testName: testName,
                               outcome: .skipped(reason: "multi-collection parameterized test"))]
        }
        let collection: [RuntimeValue]
        do {
            guard let array = try interpreter
                .evaluateGlobalExpression(elements[argumentsIndex].expression).arrayValue else {
                return [TestResult(className: symbol.name, testName: testName,
                                   outcome: .skipped(reason: "unevaluable arguments collection"))]
            }
            collection = array
        } catch {
            return [TestResult(className: symbol.name, testName: testName,
                               outcome: .skipped(reason: "arguments collection threw: \(error)"))]
        }
        return collection.enumerated().map { index, element in
            runSingle("\(testName)[\(index)]", methodName: testName, of: symbol,
                      arguments: [element], interpreter: interpreter, recorder: recorder)
        }
    }

    // MARK: - Single-test execution

    private static func runSingle(
        _ displayName: String, methodName: String? = nil, of symbol: StructSymbol,
        arguments: [RuntimeValue] = [],
        interpreter: Interpreter, recorder: AssertionRecorder
    ) -> TestResult {
        let method = methodName ?? displayName
        recorder.reset()
        do {
            // Both frameworks: a FRESH instance per test.
            guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
                return TestResult(className: symbol.name, testName: displayName,
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
            _ = try interpreter.callMethod(named: method, on: instance, arguments: arguments)
            if recorder.failures.isEmpty {
                return TestResult(className: symbol.name, testName: displayName, outcome: .passed)
            }
            return TestResult(className: symbol.name, testName: displayName,
                              outcome: .failed(reasons: recorder.failures))
        } catch let error as RuntimeError {
            // Assertion-shaped throws are failures, not harness errors —
            // native XCTUnwrap/#require record an issue and stop the test.
            if error.message.hasPrefix("#require failed") || error.message.hasPrefix("XCTUnwrap failed") {
                let reasons = recorder.failures.isEmpty ? [error.description] : recorder.failures
                return TestResult(className: symbol.name, testName: displayName,
                                  outcome: .failed(reasons: reasons))
            }
            return TestResult(className: symbol.name, testName: displayName,
                              outcome: .errored(message: error.description))
        } catch {
            return TestResult(className: symbol.name, testName: displayName,
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
