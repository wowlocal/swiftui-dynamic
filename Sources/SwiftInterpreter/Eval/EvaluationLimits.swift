import SwiftSyntax

extension Interpreter {
    // MARK: - Errors & budget

    func error(_ node: some SyntaxProtocol, _ message: String) -> RuntimeError {
        guard let location = locationConverter?.location(for: node.positionAfterSkippingLeadingTrivia) else {
            return RuntimeError(message: message)
        }
        return RuntimeError(message: message, line: location.line, column: location.column)
    }

    func tick(_ node: some SyntaxProtocol) throws {
        steps += 1
        if steps > stepBudget {
            let located = error(node, "evaluation budget exceeded (possible infinite loop)")
            throw RuntimeError(
                message: located.message, line: located.line, column: located.column,
                fatal: true, budgetTrip: true)
        }
    }
}
