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
        // Task cancellation lookup is appreciably more expensive than the
        // integer budget check. Poll immediately, then once per 64 syntax
        // nodes; cancellation remains prompt without taxing every AST node.
        if steps & 63 == 1 { try checkRuntimeCancellation() }
        if steps > stepBudget {
            let located = error(node, "evaluation budget exceeded (possible infinite loop)")
            throw RuntimeError(
                message: located.message, line: located.line, column: located.column,
                fatal: true, budgetTrip: true)
        }
    }

    /// A `for-in` sequence is fully materialized before execution, so the
    /// loop itself has a compiler-like proof of finite progress. Give each
    /// element body an independent bounded slice and charge the enclosing
    /// evaluation one step per completed element. This permits legitimate
    /// nested finite work (image pixels, matrix transforms) without weakening
    /// the guard for `while true`, recursion, or an infinite loop inside an
    /// element body: each of those still exhausts its own full step budget.
    func withFiniteIterationSlice<T>(
        _ body: () throws -> T
    ) throws -> T {
        let enclosingSteps = steps
        steps = 0
        defer { steps = enclosingSteps + 1 }
        return try body()
    }

    /// Suspending counterpart of `withFiniteIterationSlice`. Evaluator state
    /// is task-owned, so actor reentrancy cannot mix another task's counter
    /// into this slice while the body awaits.
    func withFiniteIterationSlice<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        let enclosingSteps = steps
        steps = 0
        defer { steps = enclosingSteps + 1 }
        return try await body()
    }

    /// Source-task cancellation is cooperative: it becomes visible through
    /// `Task.isCancelled`, explicit checks, and cancellable suspension APIs.
    /// Only root-host cancellation or session teardown aborts the evaluator at
    /// arbitrary safe points.
    func checkRuntimeCancellation() throws {
        guard Task.isCancelled else { return }
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            throw InterpreterSessionAbort()
        }
        guard concurrencyRuntime.requiresSessionAbort(taskID) else { return }
        concurrencyRuntime.observeCancellation(taskID)
        throw InterpreterSessionAbort()
    }

    func observeSourceCancellation() {
        guard Task.isCancelled,
              let taskID = evaluationTaskContext.runtimeTaskID else { return }
        concurrencyRuntime.observeCancellation(
            taskID, inferredSource: .inherited)
    }
}
