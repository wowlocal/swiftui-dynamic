extension Interpreter {
    func sourceUnsupportedUnsafeContinuationFunction(
        name: String
    ) -> HostFunction {
        HostFunction(
            name: name,
            tracksHostOperation: false,
            asyncInvoke: { _, _ in
                throw RuntimeError(message:
                    "\(name): unsafe continuation ownership is unsupported; "
                        + "use a checked continuation")
            })
    }
}
