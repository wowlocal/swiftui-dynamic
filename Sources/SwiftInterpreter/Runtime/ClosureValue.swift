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
        /// Cached textual form of `typeAnnotation`. SwiftSyntax descriptions
        /// are surprisingly expensive to materialize on every invocation.
        public let typeName: String?
        /// Cached return type for function-typed builder parameters.
        public let builderReturnType: TypeSyntax?
        public let builderReturnTypeName: String?
        /// `@ViewBuilder`/custom `@…Builder` parameter: closure arguments
        /// bound here undergo the result-builder transform.
        public let isBuilderAttributed: Bool
        /// `arguments: CVarArg...` — gathers zero-or-more into an array.
        public let isVariadic: Bool

        public init(
            name: String, label: String? = nil, defaultValue: ExprSyntax? = nil,
            typeAnnotation: TypeSyntax? = nil, isBuilderAttributed: Bool = false,
            isVariadic: Bool = false
        ) {
            self.name = name
            self.label = label
            self.defaultValue = defaultValue
            self.typeAnnotation = typeAnnotation
            self.typeName = typeAnnotation?.trimmedDescription
            let builderReturnType = Self.functionReturnType(of: typeAnnotation)
            self.builderReturnType = builderReturnType
            self.builderReturnTypeName = builderReturnType?.trimmedDescription
            self.isBuilderAttributed = isBuilderAttributed
            self.isVariadic = isVariadic
        }

        /// `@FloatingActionBuilder actions: () -> [FloatingAction]` — the
        /// attributes live on the parameter's type node.
        public static func isBuilderAttributedType(_ type: TypeSyntax?) -> Bool {
            guard let attributed = type?.as(AttributedTypeSyntax.self) else { return false }
            return attributed.attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
            }
        }

        /// The return type of a function-typed parameter (attributes peeled),
        /// so builder calls know array-annotated blocks collect into arrays.
        public static func functionReturnType(of type: TypeSyntax?) -> TypeSyntax? {
            var base = type
            if let attributed = base?.as(AttributedTypeSyntax.self) { base = attributed.baseType }
            return base?.as(FunctionTypeSyntax.self)?.returnClause.type
        }
    }

    public let parameters: [Parameter]
    public let body: CodeBlockItemListSyntax
    public let captured: Environment
    public let isBuilder: Bool
    /// Used to resolve returned `.member` values against known enums.
    public let returnType: TypeSyntax?
    /// Cached textual form used by return-value coercion.
    public let returnTypeName: String?
    /// `[Element]` result builders collect items into an array.
    public let builderReturnsArray: Bool
    /// Set for host-extension METHOD bodies (`extension View { func … }`):
    /// while this frame is active, a same-named self-call prefers the
    /// registry gateway — real overload resolution for the ubiquitous
    /// "convenience overload of a SwiftUI modifier" pattern.
    public var extensionFrame: ExtensionFrame?
    /// The FunctionDecl this closure wraps (method/function bodies):
    /// self-delegating overload calls exclude the RUNNING declaration.
    public var functionDeclID: SyntaxIdentifier?
    /// The type whose body/extension LEXICALLY declares this function —
    /// bare type names inside it resolve against THIS scope, not the
    /// runtime self (protocol-extension bodies see module scope).
    public var lexicalOwner: AnyObject?
    /// Generic parameter NAMES (`func get<Entity: Decodable>`): return-
    /// position ones bind to the call-site annotation at invocation.
    public var genericParameters: [String] = []
    /// The declared function name, for diagnostics tracing only.
    public var debugName: String?

    public init(
        parameters: [Parameter],
        body: CodeBlockItemListSyntax,
        captured: Environment,
        isBuilder: Bool = false,
        returnType: TypeSyntax? = nil,
        returnTypeName: String? = nil
    ) {
        self.parameters = parameters
        self.body = body
        self.captured = captured
        self.isBuilder = isBuilder
        self.returnType = returnType
        self.returnTypeName = returnTypeName ?? returnType?.trimmedDescription
        self.builderReturnsArray = self.returnTypeName?.hasPrefix("[") == true
    }
}

/// Identity of a host-extension method execution (type + member).
public struct ExtensionFrame: Hashable {
    public let typeName: String
    public let member: String
}
