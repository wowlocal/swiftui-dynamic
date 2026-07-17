import Foundation

/// A located evaluation or parse error, surfaced verbatim in the demo's error bar.
public struct RuntimeError: Error, CustomStringConvertible {
    public let message: String
    public let line: Int
    public let column: Int
    /// Fatal errors (step-budget trips) are never catchable by interpreted
    /// `do`/`catch` — the infinite-loop guard must survive user code.
    public let fatal: Bool
    /// True only for step-budget trips — the one fatal kind background-task
    /// slices may park on (a spinning task keeps its core on device; a
    /// recursion crash would kill the device process too, so it stays fatal).
    public let budgetTrip: Bool

    public init(message: String, line: Int = 0, column: Int = 0, fatal: Bool = false, budgetTrip: Bool = false) {
        self.message = message
        self.line = line
        self.column = column
        self.fatal = fatal
        self.budgetTrip = budgetTrip
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

/// Lightweight process diagnostics that may outlive an interpreter session.
/// Runtime source tokens retain this sink rather than the interpreter/runtime,
/// so a final-release warning never becomes a session-ownership edge.
nonisolated final class RuntimeDiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWarnings: [String] = []
    private let writesToStandardError: Bool

    init(writesToStandardError: Bool = true) {
        self.writesToStandardError = writesToStandardError
    }

    var warnings: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedWarnings
    }

    func emitWarning(_ message: String) {
        let terminated = message.hasSuffix("\n") ? message : message + "\n"
        lock.lock()
        storedWarnings.append(terminated)
        if writesToStandardError {
            FileHandle.standardError.write(Data(terminated.utf8))
        }
        lock.unlock()
    }
}
