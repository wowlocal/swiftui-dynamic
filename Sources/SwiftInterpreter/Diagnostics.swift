/// A located evaluation or parse error, surfaced verbatim in the demo's error bar.
public struct RuntimeError: Error, CustomStringConvertible {
    public let message: String
    public let line: Int
    public let column: Int
    /// Fatal errors (step-budget trips) are never catchable by interpreted
    /// `do`/`catch` — the infinite-loop guard must survive user code.
    public let fatal: Bool

    public init(message: String, line: Int = 0, column: Int = 0, fatal: Bool = false) {
        self.message = message
        self.line = line
        self.column = column
        self.fatal = fatal
    }

    public var description: String { "\(line):\(column): \(message)" }
}

/// A value thrown by interpreted `throw` — caught by interpreted `catch`,
/// where the binding sees the original value (enum case, instance, …).
public struct InterpretedThrow: Error {
    public let value: RuntimeValue

    public init(value: RuntimeValue) {
        self.value = value
    }
}

/// An error thrown where no syntax node is at hand (e.g. inside the operator
/// table); the evaluator catches it and re-throws with a source location.
struct EvalMessage: Error {
    let text: String
}
