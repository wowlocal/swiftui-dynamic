import SwiftSyntax

extension Interpreter {
    // MARK: - Errors & budget

    func error(_ node: some SyntaxProtocol, _ message: String) -> RuntimeError {
        guard let location = locationConverter?.location(for: node.positionAfterSkippingLeadingTrivia) else {
            return RuntimeError(message: message)
        }
        return RuntimeError(message: message, line: location.line, column: location.column)
    }

    /// Attach a source location without changing the failure's control-flow
    /// semantics. Runtime traps must remain fatal across gateway boundaries.
    func error(
        _ node: some SyntaxProtocol,
        locating source: RuntimeError
    ) -> RuntimeError {
        let located = error(node, source.message)
        return RuntimeError(
            message: located.message,
            line: located.line,
            column: located.column,
            fatal: source.fatal,
            budgetTrip: source.budgetTrip)
    }

    func tick(_ node: some SyntaxProtocol) throws {
        try tick(node, in: evaluationTaskContext)
    }

    /// The budget tick against an ALREADY-resolved owning context. Callers on
    /// the per-node path resolve the context once and hand it to every piece
    /// of bookkeeping the node needs; `steps` alone is a get and a set, and
    /// each goes through a task-local read and a weak load to find the same
    /// object the caller is already holding.
    func tick(
        _ node: some SyntaxProtocol,
        in context: EvaluationTaskContext
    ) throws {
        let steps = context.steps + 1
        context.steps = steps
        // Task cancellation lookup is appreciably more expensive than the
        // integer budget check. Poll immediately, then once per 64 syntax
        // nodes; cancellation remains prompt without taxing every AST node.
        if steps & 63 == 1 { try checkRuntimeCancellation() }
        if steps > stepBudget {
            throw evaluationBudgetExceeded(at: node)
        }
    }

    private func evaluationBudgetExceeded(
        at node: some SyntaxProtocol
    ) -> RuntimeError {
        let located = error(
            node, "evaluation budget exceeded (possible infinite loop)")
        return RuntimeError(
            message: located.message, line: located.line,
            column: located.column, fatal: true, budgetTrip: true)
    }

    /// A `for-in` sequence is fully materialized before execution, so the
    /// loop itself has a compiler-like proof of finite progress. Give each
    /// element body an independent bounded slice without charging its known-
    /// finite cardinality to the enclosing infinite-work budget. This permits legitimate
    /// nested finite work (image pixels, matrix transforms) without weakening
    /// the guard for `while true`, recursion, or an infinite loop inside an
    /// element body: each of those still exhausts its own full step budget.
    func withFiniteIterationSlice<T>(
        _ body: () throws -> T
    ) throws -> T {
        let enclosingSteps = steps
        steps = 0
        defer { steps = enclosingSteps }
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
        defer { steps = enclosingSteps }
        return try await body()
    }

    /// `while`/`repeat` cardinality is not known up front, so each loop keeps
    /// an explicit iteration cap. Once that cap is enforced, cumulative tree-
    /// walking cost across distinct iterations is not evidence of non-
    /// termination: bound each condition/body attempt independently. A single
    /// runaway attempt still exhausts the syntax budget, while `while true`
    /// exhausts the iteration budget.
    func withBoundedLoopIterationSlice<T>(
        _ iteration: Int,
        node: some SyntaxProtocol,
        _ body: () throws -> T
    ) throws -> T {
        guard iteration <= stepBudget else {
            throw evaluationBudgetExceeded(at: node)
        }
        let enclosingSteps = steps
        steps = 0
        defer { steps = enclosingSteps }
        return try body()
    }

    /// Suspending counterpart of `withBoundedLoopIterationSlice`.
    func withBoundedLoopIterationSlice<T>(
        _ iteration: Int,
        node: some SyntaxProtocol,
        _ body: () async throws -> T
    ) async throws -> T {
        guard iteration <= stepBudget else {
            throw evaluationBudgetExceeded(at: node)
        }
        let enclosingSteps = steps
        steps = 0
        defer { steps = enclosingSteps }
        return try await body()
    }

    /// Source-task cancellation is cooperative: it becomes visible through
    /// `Task.isCancelled`, explicit checks, and cancellable suspension APIs.
    /// Only root-host cancellation or session teardown aborts the evaluator at
    /// arbitrary safe points.
    func checkRuntimeCancellation() throws {
        try concurrencyRuntime.throwNonthrowingCallbackFailure(
            for: evaluationTaskContext.runtimeTaskID)
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            guard Task.isCancelled else { return }
            throw InterpreterSessionAbort()
        }
        try concurrencyRuntime.throwCancellationHandlerFailure(for: taskID)
        try concurrencyRuntime.throwPriorityEscalationHandlerFailure(
            for: taskID)
        guard isSourceTaskCancellationRequested() else { return }
        guard concurrencyRuntime.requiresSessionAbort(taskID) else { return }
        concurrencyRuntime.observeCancellation(taskID)
        throw InterpreterSessionAbort()
    }

    /// Swift can make cancellation visible before a native driver exists.
    /// `Task.immediate` is the important case: a pre-cancelled group child
    /// executes its synchronous prefix before the constructor returns, so the
    /// logical runtime record is the source of truth until `attach` can forward
    /// that request to the native task.
    func isSourceTaskCancellationRequested() -> Bool {
        if Task.isCancelled { return true }
        guard let taskID = evaluationTaskContext.runtimeTaskID else {
            return false
        }
        return concurrencyRuntime.records[taskID]?.cancellation.isRequested
            == true
    }

    func checkSourceTaskCancellation() throws {
        guard isSourceTaskCancellationRequested() else { return }
        observeSourceCancellation()
        throw CancellationError()
    }

    func observeSourceCancellation() {
        guard isSourceTaskCancellationRequested(),
              let taskID = evaluationTaskContext.runtimeTaskID else { return }
        concurrencyRuntime.observeCancellation(
            taskID, inferredSource: .inherited)
    }
}
