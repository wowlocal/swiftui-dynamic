import SwiftSyntax

extension Interpreter {
    /// Evaluate a detached expression against the global environment. The
    /// bridge's test harness uses this for `@Test(arguments: …)` collections,
    /// whose expressions live in ATTRIBUTES rather than executable positions.
    public func evaluateGlobalExpression(_ expr: ExprSyntax) throws -> RuntimeValue {
        try evaluate(expr, in: globals)
    }
}
