import SwiftSyntax

extension Interpreter {
    /// Macros with a registered host implementation (#expect/#require)
    /// EXECUTE with their evaluated arguments — no expansion needed, the
    /// argument AST is right here. Returns nil when no host is registered,
    /// so callers fall back to the inert-marker behavior (#selector,
    /// #Preview, #Predicate). Statement-position macros parse as DECLS,
    /// expression-position ones as EXPRS — both funnel here.
    func invokeRegisteredMacro(
        named macroName: String,
        arguments: LabeledExprListSyntax,
        trailingClosure: ClosureExprSyntax?,
        additionalTrailingClosures: MultipleTrailingClosureElementListSyntax,
        node: some SyntaxProtocol,
        in env: Environment
    ) throws -> RuntimeValue? {
        guard let host = registry?.constructor(named: "#\(macroName)") else { return nil }
        var callArguments: [CallArguments.Argument] = []
        for labeled in arguments {
            callArguments.append(.init(
                label: labeled.label?.text, value: try evaluate(labeled.expression, in: env)))
        }
        if let trailingClosure {
            callArguments.append(.init(
                label: nil, value: .closure(makeClosure(trailingClosure, in: env)), isTrailing: true))
        }
        for extra in additionalTrailingClosures {
            callArguments.append(.init(
                label: extra.label.text, value: .closure(makeClosure(extra.closure, in: env)),
                isTrailing: true))
        }
        return try relocating(node) { try host.invoke(CallArguments(arguments: callArguments), self) }
    }
}
