import Testing
@testable import SwiftInterpreter

@Suite("Parsed program concurrency boundary")
struct ParsedProgramConcurrencyTests {
    @Test nonisolated func parsedProgramIsSendableAcrossDetachedReaders()
    async throws {
        let program = try ParsedProgram(source: """
        func answer() -> Int { 42 }
        answer()
        """)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program)

        let observations = await withTaskGroup(
            of: (Int, String).self,
            returning: [(Int, String)].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    (
                        program.syntax.statements.count,
                        program.syntax.trimmedDescription
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(observations.count == 8)
        #expect(observations.allSatisfy { $0.0 == 2 })
        #expect(Set(observations.map(\.1)).count == 1)
    }

    @Test func oneParsedProgramBacksIndependentAsyncSessions() async throws {
        let program = try ParsedProgram(source: """
        func yielding(_ value: Int) async -> Int {
            await Task.yield()
            return value
        }
        func combined() async -> Int {
            async let left = yielding(20)
            async let right = yielding(22)
            return await left + right
        }
        await combined()
        """)
        let first = Interpreter()
        let second = Interpreter()

        async let firstValue = first.runAsync(program: program)
        async let secondValue = second.runAsync(program: program)
        let values = try await [firstValue, secondValue]

        #expect(values.map(\.intValue) == [42, 42])
        #expect(first.concurrencyRuntime.activeRecordCount == 0)
        #expect(second.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test func sourceEntryStillReturnsLocatedRuntimeParseError() throws {
        do {
            _ = try Interpreter().run(source: "let value = \"")
            Issue.record("expected a parse error")
        } catch let error as RuntimeError {
            #expect(error.line == 1)
            #expect(!error.message.isEmpty)
        }
    }
}
