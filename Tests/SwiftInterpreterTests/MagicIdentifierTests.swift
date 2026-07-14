import Testing
@testable import SwiftInterpreter

@Suite("Magic identifiers")
struct MagicIdentifierTests {
    @Test func functionUsesDeclarationSpellingAndSurvivesClosureCapture()
    throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: #"""
        func noArguments() -> String {
            #function
        }

        func labeled(_ value: Int, label other: Int) -> String {
            _ = value + other
            return #function
        }

        struct Container {
            static func method(value: Int) -> String {
                #function
            }
        }

        func captured() -> () -> String {
            { #function }
        }

        [
            noArguments(),
            labeled(1, label: 2),
            Container.method(value: 3),
            captured()(),
        ]
        """#)

        #expect(result.arrayValue?.compactMap(\.stringValue) == [
            "noArguments()",
            "labeled(_:label:)",
            "method(value:)",
            "captured()",
        ])
    }

    @Test func functionUsesDeclarationSpellingInSuspendingInvocation()
    async throws {
        let interpreter = Interpreter()
        let result = try await interpreter.runAsync(source: #"""
        func asyncName(value: Int) async -> String {
            await Task.yield()
            return #function
        }

        await asyncName(value: 1)
        """#)

        #expect(result.stringValue == "asyncName(value:)")
    }
}
