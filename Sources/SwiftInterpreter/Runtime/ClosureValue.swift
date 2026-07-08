import SwiftSyntax

/// An interpreted function or closure: parameter list, body syntax, and the
/// environment captured at creation. Methods are represented as closures whose
/// captured environment has `self` bound. `isBuilder` marks `@ViewBuilder`
/// functions and `some View` returns — their bodies evaluate in builder mode.
public final class ClosureValue {
    public struct Parameter {
        public let name: String
        /// External argument label (nil for `_` and closure parameters).
        public let label: String?
        public let defaultValue: ExprSyntax?
        /// Used to resolve `.member` arguments against known enums.
        public let typeAnnotation: TypeSyntax?

        public init(name: String, label: String? = nil, defaultValue: ExprSyntax? = nil, typeAnnotation: TypeSyntax? = nil) {
            self.name = name
            self.label = label
            self.defaultValue = defaultValue
            self.typeAnnotation = typeAnnotation
        }
    }

    public let parameters: [Parameter]
    public let body: CodeBlockItemListSyntax
    public let captured: Environment
    public let isBuilder: Bool
    /// Used to resolve returned `.member` values against known enums.
    public let returnType: TypeSyntax?

    public init(
        parameters: [Parameter],
        body: CodeBlockItemListSyntax,
        captured: Environment,
        isBuilder: Bool = false,
        returnType: TypeSyntax? = nil
    ) {
        self.parameters = parameters
        self.body = body
        self.captured = captured
        self.isBuilder = isBuilder
        self.returnType = returnType
    }
}
