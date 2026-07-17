import SwiftSyntax

/// Immutable extension headers discovered once from a folded program.
///
/// All conditional-compilation branches are indexed. Runtime sessions still
/// choose the active declarations, resolve the extended symbol, and enforce
/// any supported generic-constraint behavior.
public nonisolated struct ParsedExtensionMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let extensionCount: Int
        public let dottedExtendedTypeCount: Int
        public let inheritedTypeCount: Int
        public let constrainedExtensionCount: Int
        public let genericRequirementCount: Int
        public let attributedExtensionCount: Int
        public let modifiedExtensionCount: Int

        public init(
            extensionCount: Int,
            dottedExtendedTypeCount: Int,
            inheritedTypeCount: Int,
            constrainedExtensionCount: Int,
            genericRequirementCount: Int,
            attributedExtensionCount: Int,
            modifiedExtensionCount: Int
        ) {
            self.extensionCount = extensionCount
            self.dottedExtendedTypeCount = dottedExtendedTypeCount
            self.inheritedTypeCount = inheritedTypeCount
            self.constrainedExtensionCount = constrainedExtensionCount
            self.genericRequirementCount = genericRequirementCount
            self.attributedExtensionCount = attributedExtensionCount
            self.modifiedExtensionCount = modifiedExtensionCount
        }
    }

    fileprivate let extensions: [SyntaxIdentifier: ParsedExtensionMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedExtensionMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        extensions = collector.extensions
        let values = Array(extensions.values)
        summary = Summary(
            extensionCount: values.count,
            dottedExtendedTypeCount: values.count {
                $0.extendedTypeName.contains(".")
            },
            inheritedTypeCount: values.reduce(0) {
                $0 + $1.inheritedTypeNames.count
            },
            constrainedExtensionCount: values.count {
                !$0.genericRequirements.isEmpty
            },
            genericRequirementCount: values.reduce(0) {
                $0 + $1.genericRequirements.count
            },
            attributedExtensionCount: values.count {
                !$0.attributeNames.isEmpty
            },
            modifiedExtensionCount: values.count {
                !$0.modifierNames.isEmpty
            })
    }

    func metadata(
        for declaration: ExtensionDeclSyntax
    ) -> ParsedExtensionMetadata? {
        extensions[Syntax(declaration).id]
    }
}

nonisolated struct ParsedExtensionMetadata: Sendable {
    let extendedTypeName: String
    let inheritedTypeNames: [String]
    let genericRequirements: [String]
    let attributeNames: [String]
    let modifierNames: [String]

    init(_ declaration: ExtensionDeclSyntax) {
        extendedTypeName = declaration.extendedType.trimmedDescription
        inheritedTypeNames = declaration.inheritanceClause?.inheritedTypes
            .map { $0.type.trimmedDescription } ?? []
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
    }
}

private nonisolated final class ParsedExtensionMetadataCollector:
    SyntaxVisitor
{
    var extensions: [SyntaxIdentifier: ParsedExtensionMetadata] = [:]

    override func visit(
        _ node: ExtensionDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        extensions[Syntax(node).id] = ParsedExtensionMetadata(node)
        return .visitChildren
    }
}
