import SwiftSyntax

/// One immutable capability for every syntax-derived index owned by a parsed
/// program. Runtime entries and escaped closures propagate this value instead
/// of growing a separate ownership edge for each new metadata family.
public nonisolated final class ParsedProgramMetadata: Sendable {
    public let declarationIndex: ParsedDeclarationIndex
    public let callableMetadataIndex: ParsedCallableMetadataIndex
    public let nominalMetadataIndex: ParsedNominalMetadataIndex
    public let propertyMetadataIndex: ParsedPropertyMetadataIndex
    public let enumCaseMetadataIndex: ParsedEnumCaseMetadataIndex
    public let extensionMetadataIndex: ParsedExtensionMetadataIndex
    public let typeAliasMetadataIndex: ParsedTypeAliasMetadataIndex
    public let deinitializerMetadataIndex: ParsedDeinitializerMetadataIndex

    init(file: SourceFileSyntax) {
        declarationIndex = ParsedDeclarationIndex(
            statements: file.statements)
        callableMetadataIndex = ParsedCallableMetadataIndex(file: file)
        nominalMetadataIndex = ParsedNominalMetadataIndex(file: file)
        propertyMetadataIndex = ParsedPropertyMetadataIndex(file: file)
        enumCaseMetadataIndex = ParsedEnumCaseMetadataIndex(file: file)
        extensionMetadataIndex = ParsedExtensionMetadataIndex(file: file)
        typeAliasMetadataIndex = ParsedTypeAliasMetadataIndex(file: file)
        deinitializerMetadataIndex = ParsedDeinitializerMetadataIndex(file: file)
    }
}
