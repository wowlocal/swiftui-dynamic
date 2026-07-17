import Foundation
import SwiftSyntax

/// Immutable type-alias headers discovered once from a folded program.
///
/// Every conditional-compilation branch and lexical scope is indexed. Runtime
/// sessions still choose active declarations and bind aliases to their own
/// mutable nominal-symbol graph.
public nonisolated struct ParsedTypeAliasMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let typeAliasCount: Int
        public let genericTypeAliasCount: Int
        public let genericParameterCount: Int
        public let genericRequirementCount: Int
        public let attributedTypeAliasCount: Int
        public let modifiedTypeAliasCount: Int
        public let nominalTargetCount: Int
        public let dottedTargetCount: Int

        public init(
            typeAliasCount: Int,
            genericTypeAliasCount: Int,
            genericParameterCount: Int,
            genericRequirementCount: Int,
            attributedTypeAliasCount: Int,
            modifiedTypeAliasCount: Int,
            nominalTargetCount: Int,
            dottedTargetCount: Int
        ) {
            self.typeAliasCount = typeAliasCount
            self.genericTypeAliasCount = genericTypeAliasCount
            self.genericParameterCount = genericParameterCount
            self.genericRequirementCount = genericRequirementCount
            self.attributedTypeAliasCount = attributedTypeAliasCount
            self.modifiedTypeAliasCount = modifiedTypeAliasCount
            self.nominalTargetCount = nominalTargetCount
            self.dottedTargetCount = dottedTargetCount
        }
    }

    fileprivate let typeAliases: [SyntaxIdentifier: ParsedTypeAliasMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedTypeAliasMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        typeAliases = collector.typeAliases
        let values = Array(typeAliases.values)
        summary = Summary(
            typeAliasCount: values.count,
            genericTypeAliasCount: values.count {
                !$0.genericParameters.isEmpty
            },
            genericParameterCount: values.reduce(0) {
                $0 + $1.genericParameters.count
            },
            genericRequirementCount: values.reduce(0) {
                $0 + $1.genericRequirements.count
            },
            attributedTypeAliasCount: values.count {
                !$0.attributeNames.isEmpty
            },
            modifiedTypeAliasCount: values.count {
                !$0.modifierNames.isEmpty
            },
            nominalTargetCount: values.count(where: \.isNominalTarget),
            dottedTargetCount: values.count {
                $0.targetTypeName.contains(".")
            })
    }

    func metadata(
        for declaration: TypeAliasDeclSyntax
    ) -> ParsedTypeAliasMetadata? {
        typeAliases[Syntax(declaration).id]
    }
}

nonisolated struct ParsedTypeAliasMetadata: Sendable {
    nonisolated struct GenericParameter: Sendable, Equatable {
        let name: String
        let inheritedTypeName: String?
    }

    let name: String
    let targetTypeName: String
    let lookupTargetName: String
    let genericParameters: [GenericParameter]
    let genericRequirements: [String]
    let attributeNames: [String]
    let modifierNames: [String]
    let isNominalTarget: Bool

    init(_ declaration: TypeAliasDeclSyntax) {
        name = declaration.name.text
        targetTypeName = declaration.initializer.value.trimmedDescription
        var lookupTargetName = targetTypeName
        if let angle = lookupTargetName.firstIndex(of: "<") {
            lookupTargetName = String(lookupTargetName[..<angle])
        }
        lookupTargetName = lookupTargetName.trimmingCharacters(
            in: .whitespaces)
        self.lookupTargetName = lookupTargetName
        genericParameters = declaration.genericParameterClause?.parameters
            .map {
                GenericParameter(
                    name: $0.name.text,
                    inheritedTypeName: $0.inheritedType?.trimmedDescription)
            } ?? []
        genericRequirements = declaration.genericWhereClause?.requirements
            .map { requirement in
                switch requirement.requirement {
                case .sameTypeRequirement(let value):
                    value.trimmedDescription
                case .conformanceRequirement(let value):
                    value.trimmedDescription
                case .layoutRequirement(let value):
                    value.trimmedDescription
                }
            } ?? []
        attributeNames = declaration.attributes.compactMap {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
        }
        modifierNames = declaration.modifiers.map { $0.name.text }
        isNominalTarget = lookupTargetName.first?.isUppercase == true
            && !lookupTargetName.contains("(")
    }
}

private nonisolated final class ParsedTypeAliasMetadataCollector:
    SyntaxVisitor
{
    var typeAliases: [SyntaxIdentifier: ParsedTypeAliasMetadata] = [:]

    override func visit(
        _ node: TypeAliasDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        typeAliases[Syntax(node).id] = ParsedTypeAliasMetadata(node)
        return .visitChildren
    }
}
