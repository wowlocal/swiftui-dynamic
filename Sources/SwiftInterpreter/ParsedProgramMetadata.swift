import Foundation
import SwiftSyntax

private nonisolated struct ParsedSourceModuleRegion: Sendable {
    let moduleName: String?
    let importedModuleNames: Set<String>
    let utf8Range: Range<Int>
}

/// Stable identity of one compiler input after several files have been
/// flattened into a single parser input. The byte offset is unique only
/// within its owning metadata capability, so both properties participate in
/// identity.
nonisolated struct RuntimeSourceFileIdentity: Sendable, Hashable {
    let metadataIdentity: ObjectIdentifier
    let regionStartUTF8Offset: Int
}

/// One immutable capability for every syntax-derived index owned by a parsed
/// program. Runtime entries and escaped closures propagate this value instead
/// of growing a separate ownership edge for each new metadata family.
public nonisolated final class ParsedProgramMetadata: Sendable {
    /// Modules visible to this source projection. `Swift` is implicit in
    /// every Swift file; explicit imports and merge-preserved provenance
    /// directives contribute the rest. Runtime module-qualified lookup uses
    /// this property instead of a framework-name allowlist.
    public let importedModuleNames: Set<String>
    private let sourceModuleRegions: [ParsedSourceModuleRegion]
    public let declarationIndex: ParsedDeclarationIndex
    public let callableMetadataIndex: ParsedCallableMetadataIndex
    public let callSiteMetadataIndex: ParsedCallSiteMetadataIndex
    public let memberMetadataIndex: ParsedMemberMetadataIndex
    public let nominalMetadataIndex: ParsedNominalMetadataIndex
    public let propertyMetadataIndex: ParsedPropertyMetadataIndex
    public let enumCaseMetadataIndex: ParsedEnumCaseMetadataIndex
    public let extensionMetadataIndex: ParsedExtensionMetadataIndex
    public let typeAliasMetadataIndex: ParsedTypeAliasMetadataIndex
    public let deinitializerMetadataIndex: ParsedDeinitializerMetadataIndex

    init(file: SourceFileSyntax) {
        let source = file.description
        var importedModuleNames: Set<String> = ["Swift"]
        for statement in file.statements {
            guard case .decl(let declaration) = statement.item,
                  let importDeclaration = declaration.as(ImportDeclSyntax.self),
                  let module = importDeclaration.path.first?.name.text,
                  !module.isEmpty
            else { continue }
            importedModuleNames.insert(module)
        }
        let provenancePrefix = "// swift-interpreter-module "
        for line in source.split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(provenancePrefix) else { continue }
            let module = String(trimmed.dropFirst(provenancePrefix.count))
            guard !module.isEmpty,
                  module.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { continue }
            importedModuleNames.insert(module)
        }
        self.importedModuleNames = importedModuleNames
        sourceModuleRegions = Self.sourceModuleRegions(in: source)
        declarationIndex = ParsedDeclarationIndex(
            statements: file.statements)
        callableMetadataIndex = ParsedCallableMetadataIndex(file: file)
        callSiteMetadataIndex = ParsedCallSiteMetadataIndex(file: file)
        memberMetadataIndex = ParsedMemberMetadataIndex(file: file)
        nominalMetadataIndex = ParsedNominalMetadataIndex(file: file)
        propertyMetadataIndex = ParsedPropertyMetadataIndex(file: file)
        enumCaseMetadataIndex = ParsedEnumCaseMetadataIndex(file: file)
        extensionMetadataIndex = ParsedExtensionMetadataIndex(file: file)
        typeAliasMetadataIndex = ParsedTypeAliasMetadataIndex(file: file)
        deinitializerMetadataIndex = ParsedDeinitializerMetadataIndex(file: file)
    }

    func sourceModuleName(at position: AbsolutePosition) -> String? {
        sourceModuleRegion(at: position)?.moduleName
    }

    func sourceImportedModuleNames(
        at position: AbsolutePosition
    ) -> Set<String>? {
        sourceModuleRegion(at: position)?.importedModuleNames
    }

    func sourceFileIdentity(
        at position: AbsolutePosition
    ) -> RuntimeSourceFileIdentity? {
        guard let region = sourceModuleRegion(at: position) else {
            return nil
        }
        return RuntimeSourceFileIdentity(
            metadataIdentity: ObjectIdentifier(self),
            regionStartUTF8Offset: region.utf8Range.lowerBound)
    }

    private func sourceModuleRegion(
        at position: AbsolutePosition
    ) -> ParsedSourceModuleRegion? {
        let offset = position.utf8Offset
        var lowerBound = 0
        var upperBound = sourceModuleRegions.count
        while lowerBound < upperBound {
            let index = lowerBound + (upperBound - lowerBound) / 2
            let region = sourceModuleRegions[index]
            if offset < region.utf8Range.lowerBound {
                upperBound = index
            } else if offset >= region.utf8Range.upperBound {
                lowerBound = index + 1
            } else {
                return region
            }
        }
        return nil
    }

    /// Generated start/end directives bracket exact SwiftPM compiler inputs.
    /// Byte ranges preserve ownership after imports are stripped and sources
    /// are flattened into one parser input; source text cannot accidentally
    /// leak ownership past its matching end directive.
    private static func sourceModuleRegions(
        in source: String
    ) -> [ParsedSourceModuleRegion] {
        let startPrefix = "// swift-interpreter-source-module "
        let fileStartDirective = "// swift-interpreter-source-file"
        let importPrefix = "// swift-interpreter-source-import "
        let endDirective = "// swift-interpreter-source-module-end"
        let bytes = Array(source.utf8)
        var result: [ParsedSourceModuleRegion] = []
        var active: (
            moduleName: String?,
            importedModuleNames: Set<String>,
            start: Int
        )?
        var lineStart = 0

        while lineStart <= bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 10 {
                lineEnd += 1
            }
            let line = String(decoding: bytes[lineStart..<lineEnd], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line == fileStartDirective {
                active = (
                    nil,
                    ["Swift"],
                    min(lineEnd + 1, bytes.count))
            } else if line.hasPrefix(startPrefix) {
                let moduleName = String(line.dropFirst(startPrefix.count))
                if !moduleName.isEmpty,
                   moduleName.allSatisfy({
                       $0.isLetter || $0.isNumber || $0 == "_"
                   })
                {
                    active = (
                        Optional(moduleName),
                        ["Swift"],
                        min(lineEnd + 1, bytes.count))
                } else {
                    active = nil
                }
            } else if line.hasPrefix(importPrefix), active != nil {
                let moduleName = String(line.dropFirst(importPrefix.count))
                if !moduleName.isEmpty,
                   moduleName.allSatisfy({
                       $0.isLetter || $0.isNumber || $0 == "_"
                   })
                {
                    active?.importedModuleNames.insert(moduleName)
                }
            } else if line == endDirective, let region = active {
                if region.start < lineStart {
                    result.append(ParsedSourceModuleRegion(
                        moduleName: region.moduleName,
                        importedModuleNames: region.importedModuleNames,
                        utf8Range: region.start..<lineStart))
                }
                active = nil
            }
            guard lineEnd < bytes.count else { break }
            lineStart = lineEnd + 1
        }
        return result
    }
}
