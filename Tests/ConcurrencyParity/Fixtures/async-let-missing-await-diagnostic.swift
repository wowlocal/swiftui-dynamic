func asyncLetDiagnosticValue() async -> String {
    "value"
}

func asyncLetMissingAwait() async -> String {
    async let value = asyncLetDiagnosticValue()
    return value
}
