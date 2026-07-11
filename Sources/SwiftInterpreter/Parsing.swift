import SwiftSyntax
import SwiftParser
import SwiftOperators
import SwiftParserDiagnostics

extension Interpreter {
    /// Formatting recoveries that parse to a CORRECT tree — the compiler
    /// accepts these spellings too.
    public static func isToleratedParseRecovery(_ message: String) -> Bool {
        message.contains("extraneous whitespace")
            // The `(@MainActor() -> Void)?` no-space family: the attribute
            // swallows the parens, SwiftParser recovers to a correct tree,
            // and Xcode accepts the spelling.
            || message.contains("expected '(' to start function type")
            || message.contains("expected ')' in function type")
            || message.contains("expected '(', type, and ')' in function type")
            // `throws async` — the parser recovers by normalizing effect
            // order; the tree carries both effects correctly.
            || message.contains("must precede 'throws'")
    }

    /// True when the source has HARD parse errors (recovered formatting
    /// diagnostics don't count) — such a file can't be a member of any
    /// compiling target (Sourcery scratch fragments, abandoned files with
    /// editor placeholders).
    public static func sourceHasHardErrors(_ source: String) -> Bool {
        let tree = Parser.parse(source: source)
        return ParseDiagnosticsGenerator.diagnostics(for: tree).contains {
            $0.diagMessage.severity == .error && !isToleratedParseRecovery($0.message)
        }
    }

    // MARK: - Parsing

    public func parse(source: String) throws -> SourceFileSyntax {
        // SwiftParser's default nesting ceiling (~256) trips on generated
        // preview fixtures (apple-browsers nests bookmark literals dozens
        // deep). Evaluation has its own stack probe; parsing gets headroom.
        var parser = Parser(source, maximumNestingLevel: 2_048)
        let tree = SourceFileSyntax.parse(from: &parser)
        let converter = SourceLocationConverter(fileName: "input.swift", tree: tree)
        locationConverter = converter

        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        if let firstError = diagnostics.first(where: {
            $0.diagMessage.severity == .error && !Self.isToleratedParseRecovery($0.message)
        }) {
            let location = converter.location(for: firstError.position)
            throw RuntimeError(message: firstError.message, line: location.line, column: location.column)
        }

        var operatorErrors: [OperatorError] = []
        // User-declared operators and precedence groups (Point-Free's
        // `|>` pipe) join the fold table; conflicts with the standard set
        // are tolerated (last declaration wins inside addSourceFile).
        var table = OperatorTable.standardOperators
        try? table.addSourceFile(tree) { _ in }
        let folded = table.foldAll(tree) { operatorErrors.append($0) }
        if let first = operatorErrors.first(where: {
            // Operators declared in EXTERNAL modules (Overture's `|>`)
            // recover with default precedence — the evaluator gives them
            // meaning (or absorbs). Other fold errors stay fatal.
            if case .missingOperator = $0 { return false }
            return true
        }) {
            throw RuntimeError(message: "operator error: \(first)", line: 1, column: 1)
        }
        guard let foldedFile = folded.as(SourceFileSyntax.self) else {
            throw RuntimeError(message: "internal error: operator folding failed", line: 1, column: 1)
        }
        return foldedFile
    }
}
