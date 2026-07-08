import SwiftSyntax

/// An interpreted function or closure: parameter list, body syntax, and the
/// environment captured at creation. Methods are represented as closures whose
/// captured environment has `self` bound.
public final class ClosureValue {
    public struct Parameter {
        public let name: String
        public let defaultValue: ExprSyntax?

        public init(name: String, defaultValue: ExprSyntax? = nil) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    public let parameters: [Parameter]
    public let body: CodeBlockItemListSyntax
    public let captured: Environment

    public init(parameters: [Parameter], body: CodeBlockItemListSyntax, captured: Environment) {
        self.parameters = parameters
        self.body = body
        self.captured = captured
    }
}
