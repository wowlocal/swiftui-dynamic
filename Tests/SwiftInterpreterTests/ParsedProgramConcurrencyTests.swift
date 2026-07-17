import Testing
@testable import SwiftInterpreter

@Suite("Parsed program concurrency boundary")
struct ParsedProgramConcurrencyTests {
    @Test nonisolated func parsedProgramOwnsSendableDeclarationIndex()
    async throws {
        let program = try ParsedProgram(source: """
        struct Box {}
        func value() -> Int { 1 }
        let global = value()
        typealias Alias = Box
        extension Box {}
        #if os(iOS)
        actor Worker {}
        #else
        enum Worker {}
        #endif
        """)

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(program.declarationIndex)
        let expected = ParsedDeclarationIndex.Summary(
            possiblePrimaryDeclarationCount: 5,
            possibleTypeAliasCount: 1,
            possibleExtensionCount: 1,
            conditionalRegionCount: 1)
        #expect(program.declarationIndex.summary == expected)

        let observations = await withTaskGroup(
            of: ParsedDeclarationIndex.Summary.self,
            returning: [ParsedDeclarationIndex.Summary].self
        ) { group in
            for _ in 0..<8 {
                group.addTask { program.declarationIndex.summary }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(observations.count == 8)
        #expect(observations.allSatisfy { $0 == expected })
    }

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

    @Test func sessionsBindBuildResolvedDeclarationPlans() async throws {
        let program = try ParsedProgram(source: """
        #if os(iOS)
        struct Selected { let base = 40 }
        typealias Alias = Selected
        extension Selected { var answer: Int { base + 2 } }
        #else
        struct Selected { let base = 20 }
        typealias Alias = Selected
        extension Selected { var answer: Int { base + 1 } }
        #endif
        Alias().answer
        """)
        let ios = Interpreter(buildConfiguration: .init(
            platformName: "iOS", activeCompilationConditions: []))
        let mac = Interpreter(buildConfiguration: .init(
            platformName: "macOS", activeCompilationConditions: []))
        let iosSession = ios.makeSession(program: program)
        let macSession = mac.makeSession(program: program)

        #expect(program.declarationIndex.summary
            .possiblePrimaryDeclarationCount == 2)
        #expect(program.declarationIndex.summary
            .possibleTypeAliasCount == 2)
        #expect(program.declarationIndex.summary
            .possibleExtensionCount == 2)
        #expect(iosSession.executionPlan.primaryDeclarations.count == 1)
        #expect(macSession.executionPlan.primaryDeclarations.count == 1)
        #expect(iosSession.executionPlan.typeAliases.count == 1)
        #expect(macSession.executionPlan.typeAliases.count == 1)
        #expect(iosSession.executionPlan.extensionDeclarations.count == 1)
        #expect(macSession.executionPlan.extensionDeclarations.count == 1)
        #expect(iosSession.executionPlan.topLevelItems.count == 4)
        #expect(macSession.executionPlan.topLevelItems.count == 4)

        let iosValue = try await ios.runAsync(session: iosSession)
        let macValue = try await mac.runAsync(session: macSession)
        #expect(iosValue.intValue == 42)
        #expect(macValue.intValue == 21)
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
