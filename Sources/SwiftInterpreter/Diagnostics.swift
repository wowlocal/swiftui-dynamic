/// A located evaluation or parse error, surfaced verbatim in the demo's error bar.
public struct RuntimeError: Error, CustomStringConvertible {
    public let message: String
    public let line: Int
    public let column: Int

    public init(message: String, line: Int = 0, column: Int = 0) {
        self.message = message
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column): \(message)" }
}

/// An error thrown where no syntax node is at hand (e.g. inside the operator
/// table); the evaluator catches it and re-throws with a source location.
struct EvalMessage: Error {
    let text: String
}
