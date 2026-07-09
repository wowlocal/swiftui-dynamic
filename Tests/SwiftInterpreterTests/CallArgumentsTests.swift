import Testing
@testable import SwiftInterpreter

@Suite struct CallArgumentsTests {
    @Test func positionalAndClosureLookupsPreserveSourceOrder() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        let first = { 1 }
        let second = { 2 }
        """)
        guard let first = interpreter.globals.lookup("first")?.closureValue,
              let second = interpreter.globals.lookup("second")?.closureValue else {
            Issue.record("expected interpreted closures")
            return
        }

        let arguments = CallArguments(arguments: [
            .init(label: "title", value: .native("ignored")),
            .init(label: nil, value: .native(10)),
            .init(label: nil, value: .closure(first), isTrailing: true),
            .init(label: nil, value: .native(20)),
            .init(label: nil, value: .closure(second), isTrailing: true),
        ])

        #expect(arguments.positional(-1) == nil)
        #expect(arguments.positional(0)?.intValue == 10)
        #expect(arguments.positional(1)?.intValue == 20)
        #expect(arguments.positional(2) == nil)
        #expect(try interpreter.callClosure(arguments.firstUnlabeledClosure!, arguments: []).intValue == 1)
        #expect(try interpreter.callClosure(arguments.lastUnlabeledClosure!, arguments: []).intValue == 2)
        #expect(arguments.unlabeledClosures.count == 2)
    }
}
