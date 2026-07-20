import Testing
@testable import SwiftInterpreter

@Suite struct ModuleQualifiedOverloadTests {
    @Test func qualifierPreservesSameShapedGlobalOverloadFamily() throws {
        let source = """
        import ParserKit

        func parse(_ value: String) -> String {
            "string"
        }

        func parse(_ value: Int) -> String {
            "int"
        }

        ParserKit.parse(42)
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "int")
    }
}
