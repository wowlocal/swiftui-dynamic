extension Builtins {
    /// Public faces for the bridge's XCTest harness: assertions must compare
    /// interpreted values with the exact semantics the interpreter uses.
    public static func equalValues(_ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> Bool {
        try areEqual(lhs, rhs)
    }

    public static func compareValues(_ op: String, _ lhs: RuntimeValue, _ rhs: RuntimeValue) throws -> RuntimeValue {
        try binary(op, lhs, rhs)
    }
}
