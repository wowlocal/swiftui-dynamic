extension Interpreter {
    func sourceUnsafeContinuationFunction(
        name: String,
        allowsThrowingResume: Bool
    ) -> HostFunction {
        sourceContinuationFunction(
            name: name,
            policy: .unsafe,
            allowsThrowingResume: allowsThrowingResume)
    }
}
