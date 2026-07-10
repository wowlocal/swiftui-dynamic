import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct RangeBridgeTests {
    private func render(_ source: String) throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let root) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("root view was not instantiated")
            return
        }
        _ = try interpreter.evaluateBody(of: root)
    }

    @Test func sliderRequiresClosedRange() throws {
        let valid = """
        struct ContentView: View {
            @State var value: Double = 0
            var body: some View { Slider(value: $value, in: 0...10) }
        }
        """
        try render(valid)

        let invalid = """
        struct ContentView: View {
            @State var value: Double = 0
            var body: some View { Slider(value: $value, in: 0..<10) }
        }
        """
        do {
            try render(invalid)
            Issue.record("expected half-open Slider bounds to fail")
        } catch let error as RuntimeError {
            #expect(error.message.contains("closed range"))
        }
    }

    @Test func integerAndDoubleRandomAcceptOpenAndClosedRanges() throws {
        let source = """
        let intOpen = Int.random(in: 4..<5)
        let intClosed = Int.random(in: 7...7)
        let doubleOpen = Double.random(in: 1.5..<2.5)
        let doubleClosed = Double.random(in: 3.5...3.5)
        intOpen == 4 && intClosed == 7
            && doubleOpen >= 1.5 && doubleOpen < 2.5
            && doubleClosed == 3.5
        """
        let value = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(value.boolValue == true)
    }

    @Test func forEachMaterializesClosedIntegerRange() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    ForEach(1...3) { value in Text("\\(value)") }
                }
            }
        }
        """
        let report = try HeadlessVerifier.verify(source: source)
        #expect(report.nodeCount >= 4)
    }
}
