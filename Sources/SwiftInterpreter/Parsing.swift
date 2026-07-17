import SwiftSyntax
import SwiftParser
import SwiftOperators
import SwiftParserDiagnostics

/// Immutable, executor-neutral input to an interpreter session.
///
/// Parsing, operator folding, and target-neutral metadata discovery happen
/// once. The resulting SwiftSyntax tree, source-location index, declaration
/// plan, callable/call-site metadata, member plans, nominal headers, property-
/// storage headers, and enum-case, extension, type-alias, and deinitializer
/// headers are immutable and `Sendable`, so independent sessions may share
/// them without sharing evaluator or runtime-symbol state.
public nonisolated struct ParsedProgram: Sendable {
    public struct ParseFailure: Error, CustomStringConvertible, Sendable {
        public let message: String
        public let line: Int
        public let column: Int

        public var description: String { "\(line):\(column): \(message)" }
    }

    public let source: String
    public let fileName: String
    public let metadata: ParsedProgramMetadata
    public var declarationIndex: ParsedDeclarationIndex {
        metadata.declarationIndex
    }
    public var callableMetadataIndex: ParsedCallableMetadataIndex {
        metadata.callableMetadataIndex
    }
    public var callSiteMetadataIndex: ParsedCallSiteMetadataIndex {
        metadata.callSiteMetadataIndex
    }
    public var memberMetadataIndex: ParsedMemberMetadataIndex {
        metadata.memberMetadataIndex
    }
    public var nominalMetadataIndex: ParsedNominalMetadataIndex {
        metadata.nominalMetadataIndex
    }
    public var propertyMetadataIndex: ParsedPropertyMetadataIndex {
        metadata.propertyMetadataIndex
    }
    public var enumCaseMetadataIndex: ParsedEnumCaseMetadataIndex {
        metadata.enumCaseMetadataIndex
    }
    public var extensionMetadataIndex: ParsedExtensionMetadataIndex {
        metadata.extensionMetadataIndex
    }
    public var typeAliasMetadataIndex: ParsedTypeAliasMetadataIndex {
        metadata.typeAliasMetadataIndex
    }
    public var deinitializerMetadataIndex: ParsedDeinitializerMetadataIndex {
        metadata.deinitializerMetadataIndex
    }
    let syntax: SourceFileSyntax
    let locationConverter: SourceLocationConverter

    public init(source: String, fileName: String = "input.swift") throws {
        self.source = source
        self.fileName = fileName

        // SwiftParser's default nesting ceiling (~256) trips on generated
        // preview fixtures. Evaluation has an independent stack guard.
        var parser = Parser(source, maximumNestingLevel: 2_048)
        let tree = SourceFileSyntax.parse(from: &parser)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)

        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        if let firstError = diagnostics.first(where: {
            $0.diagMessage.severity == .error
                && !Self.isToleratedParseRecovery($0.message)
        }) {
            let location = converter.location(for: firstError.position)
            throw ParseFailure(
                message: firstError.message,
                line: location.line,
                column: location.column)
        }

        var operatorErrors: [OperatorError] = []
        // User-declared operators and precedence groups join the standard
        // fold table. External-module operators recover at default
        // precedence, matching the interpreter's historical behavior.
        var table = OperatorTable.standardOperators
        table.addSourceFile(tree) { _ in }
        let folded = table.foldAll(tree) { operatorErrors.append($0) }
        if let first = operatorErrors.first(where: {
            if case .missingOperator = $0 { return false }
            return true
        }) {
            throw ParseFailure(
                message: "operator error: \(first)", line: 1, column: 1)
        }
        guard let foldedFile = folded.as(SourceFileSyntax.self) else {
            throw ParseFailure(
                message: "internal error: operator folding failed",
                line: 1,
                column: 1)
        }

        syntax = foldedFile
        metadata = ParsedProgramMetadata(file: foldedFile)
        locationConverter = converter
    }

    /// Resolve every target-dependent declaration and member branch once,
    /// without entering an interpreter or touching mutable runtime state.
    public func resolve(
        buildConfiguration: InterpreterBuildConfiguration
    ) -> ResolvedProgramPlan {
        ResolvedProgramPlan(
            metadata: metadata,
            buildConfiguration: buildConfiguration,
            fileName: fileName,
            locationConverter: locationConverter)
    }

    public static func isToleratedParseRecovery(_ message: String) -> Bool {
        message.contains("extraneous whitespace")
            // The `(@MainActor() -> Void)?` no-space family: the attribute
            // swallows the parens, SwiftParser recovers to a correct tree,
            // and Xcode accepts the spelling.
            || message.contains("expected '(' to start function type")
            || message.contains("expected ')' in function type")
            || message.contains("expected '(', type, and ')' in function type")
            // `throws async` is recovered by normalizing effect order.
            || message.contains("must precede 'throws'")
    }

    public static func sourceHasHardErrors(_ source: String) -> Bool {
        let tree = Parser.parse(source: source)
        return ParseDiagnosticsGenerator.diagnostics(for: tree).contains {
            $0.diagMessage.severity == .error
                && !isToleratedParseRecovery($0.message)
        }
    }
}

extension Interpreter {
    /// Formatting recoveries that parse to a CORRECT tree — the compiler
    /// accepts these spellings too.
    public static func isToleratedParseRecovery(_ message: String) -> Bool {
        ParsedProgram.isToleratedParseRecovery(message)
    }

    /// True when the source has HARD parse errors (recovered formatting
    /// diagnostics don't count) — such a file can't be a member of any
    /// compiling target (Sourcery scratch fragments, abandoned files with
    /// editor placeholders).
    public static func sourceHasHardErrors(_ source: String) -> Bool {
        ParsedProgram.sourceHasHardErrors(source)
    }

    // MARK: - Parsing

    public func parse(source: String) throws -> SourceFileSyntax {
        let program = try makeParsedProgram(source: source)
        compatibilityLocationConverter = program.locationConverter
        return program.syntax
    }

    func makeParsedProgram(source: String) throws -> ParsedProgram {
        do {
            return try ParsedProgram(source: source)
        } catch let failure as ParsedProgram.ParseFailure {
            throw RuntimeError(
                message: failure.message,
                line: failure.line,
                column: failure.column)
        }
    }
}
