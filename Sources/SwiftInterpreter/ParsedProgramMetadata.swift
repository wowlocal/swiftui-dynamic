import SwiftSyntax

/// One immutable capability for every syntax-derived index owned by a parsed
/// program. Runtime entries and escaped closures propagate this value instead
/// of growing a separate ownership edge for each new metadata family.
public nonisolated struct ParsedProgramMetadata: Sendable {
    public let declarationIndex: ParsedDeclarationIndex
    public let callableMetadataIndex: ParsedCallableMetadataIndex

    init(file: SourceFileSyntax) {
        declarationIndex = ParsedDeclarationIndex(
            statements: file.statements)
        callableMetadataIndex = ParsedCallableMetadataIndex(file: file)
    }
}
