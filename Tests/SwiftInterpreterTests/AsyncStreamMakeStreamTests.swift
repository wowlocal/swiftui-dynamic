import Testing
@testable import SwiftInterpreter

// The TestCheck 115-count class: `let (stream, continuation) =
// AsyncStream<T>.makeStream()` — the tuple-returning factory composes the
// SAME runtime primitives as the closure constructor (element-x's
// deferFulfillment helper is the exemplar shape).
@Suite struct AsyncStreamMakeStreamTests {
    @Test func makeStreamDestructuresYieldsAndIterates() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: #"""
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()
        var out = ""
        for await value in stream {
            out += "\(value)"
        }
        out
        """#)
        #expect(result.stringValue == "12")
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func labeledTupleMembersResolve() async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: #"""
        let made = AsyncThrowingStream<Int, Error>.makeStream()
        made.continuation.yield(7)
        made.continuation.finish()
        var out = ""
        for try await value in made.stream {
            out += "\(value)"
        }
        out
        """#)
        #expect(result.stringValue == "7")
    }
}
