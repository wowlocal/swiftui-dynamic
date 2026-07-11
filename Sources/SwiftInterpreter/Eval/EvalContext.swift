// MARK: - EvalContext (what gateways can call back into)

extension Interpreter: EvalContext {
    public func callClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        steps = 0 // fresh entry, e.g. a Button action invoked from the UI
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        return try callWithArguments(closure, args: args, node: nil)
    }

    /// Background work (`Task { … }` bodies). On device these run
    /// concurrently, so an INTENTIONALLY infinite loop (`while true {
    /// poll(); try? await Task.sleep }`) is legitimate there — it suspends
    /// and never blocks launch. Synchronously we give the body a bounded
    /// slice and PARK it when the slice is spent: execution stops quietly
    /// and the caller's own budget is untouched. Documented divergence:
    /// parked background tasks never resume.
    public func callBackgroundClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> RuntimeValue {
        let entrySteps = steps
        let slice = 20_000
        steps = max(0, stepBudget - slice)
        defer { steps = entrySteps }
        do {
            let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
            return try callWithArguments(closure, args: args, node: nil)
        } catch let error as RuntimeError where error.budgetTrip {
            return .void // parked
        }
    }

    public func callBuilderClosure(_ closure: ClosureValue, arguments: [RuntimeValue]) throws -> [RuntimeValue] {
        let env = Environment(parent: closure.captured)
        let args = CallArguments(arguments: arguments.map { .init(label: nil, value: $0) })
        try bindParameters(of: closure, to: args, into: env, node: nil)
        return try collectBuilderViews(closure.body, in: env)
    }
}
