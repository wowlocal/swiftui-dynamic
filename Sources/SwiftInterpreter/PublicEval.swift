import SwiftSyntax

extension Interpreter {
    /// Evaluate a detached expression against the global environment. The
    /// bridge's test harness uses this for `@Test(arguments: …)` collections,
    /// whose expressions live in ATTRIBUTES rather than executable positions.
    public func evaluateGlobalExpression(_ expr: ExprSyntax) throws -> RuntimeValue {
        try evaluate(expr, in: globals)
    }

    /// Instantiate an interpreted type with labeled arguments — the bridge's
    /// structural JSON decode builds instances field by field.
    public func instantiateForBridge(_ symbol: StructSymbol, arguments: CallArguments) throws -> RuntimeValue {
        try instantiate(
            symbol, with: arguments,
            node: Syntax(DeclReferenceExprSyntax(baseName: .identifier("decodedInstance"))))
    }

    /// A declared type by name (`.type` / `.enumType`), if the program
    /// defines one — annotation-driven decode resolves element types here.
    public func typeValue(named name: String) -> RuntimeValue? {
        guard let value = globals.lookup(name) else { return nil }
        switch value {
        case .type, .enumType: return value
        default: return nil
        }
    }
}
