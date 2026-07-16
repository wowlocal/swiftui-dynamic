extension Interpreter {
    func sourceExtractIsolationFunction(
        name: String = RuntimeConcurrencyFunctionIntrinsic
            .extractIsolation.rawValue
    ) -> HostFunction {
        HostFunction(name: name) { arguments, _ in
            guard arguments.arguments.count == 1,
                  let argument = arguments.arguments.first,
                  argument.label == nil,
                  let operation = argument.value.closureValue else {
                throw RuntimeError(message:
                    "extractIsolation requires exactly one async function "
                        + "value")
            }
            guard argument.sourceProvenance
                    == .directGlobalAsyncFunctionDeclaration,
                  operation.isExplicitlyNonisolated else {
                throw RuntimeError(message:
                    "extractIsolation currently requires a bare unqualified "
                        + "direct global function declaration that is async "
                        + "and explicitly declared nonisolated")
            }

            // The supported declaration provenance proves that native Swift
            // returns nil. This is synchronous metadata inspection: never
            // invoke the operation, create a task, or change executor state.
            return .nilValue
        }
    }
}
